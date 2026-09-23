// Sources/WhisperMeet/Dictation/TextInjector.swift
import AppKit
import ApplicationServices
import CoreGraphics
import os

/// Delivers dictated text, in one of two ways.
///
/// **Clipboard only** — auto-paste is off, or no ⌘V could be synthesized (no Accessibility). The
/// text is written to the clipboard and left there: the clipboard *is* the delivery, and the user
/// pastes it themselves. Nothing is restored.
///
/// **Auto-paste** borrows the clipboard (F425). A synthesized ⌘V can only paste what is on the
/// clipboard, and before F425 the dictation stayed there afterwards, replacing whatever the user
/// had copied — including text copied on an iPhone and handed over by Universal Clipboard. Now:
///
/// 1. When a dictation starts with auto-paste on, `captureWillStart` copies the user's clipboard,
///    off the main thread, into a `PasteboardSnapshot` stamped with the `changeCount` it was read
///    under. If the clipboard still holds the previous dictation with its restore still to come,
///    that restore's snapshot is carried over instead of reading our own dictation.
/// 2. `deliver` writes the text and synthesizes ⌘V. If the snapshot is still current — nothing
///    has written to the pasteboard since it was read — a restore is scheduled `restoreDelay`
///    later.
/// 3. The restore writes the snapshot back only if the pasteboard's `changeCount` is still the
///    one the dictation's own write produced. Anything copied in between wins.
///
/// Wherever a restore cannot be shown to be right — no snapshot (no Accessibility, a system
/// setting that would ask before the read, a clipboard marked concealed, one over the size cap),
/// a snapshot that went stale, one still being read — the dictation is left on the clipboard,
/// which is the pre-F425 behaviour, and the text is also in the dictation history.
///
/// A snapshot is dropped once it has been put back (unless a dictation already under way can
/// reuse it) or a delivery has made it moot. A dictation that ends without delivering keeps its
/// snapshot until the next dictation starts, which reuses it if the clipboard has not changed and
/// drops it otherwise.
@MainActor
final class TextInjector {
    enum Delivery { case pasted, clipboard }

    /// How long after ⌘V the clipboard is put back. Nothing tells us the target app has consumed
    /// the paste, and restoring too early makes it paste the OLD content — worse than not
    /// restoring, and possibly into a message being written. The paste happens when the target
    /// app gets round to the ⌘V event, so this has to outlast that app's event-handling delay; an
    /// app stalled for longer than this when the ⌘V reaches it would paste the restored content
    /// instead. Erring long costs little: during the window the clipboard holds the dictation, and
    /// anything the user copies inside it cancels the restore rather than being overwritten.
    nonisolated static let defaultRestoreDelay: TimeInterval = 1.5

    /// A clipboard larger than this is not held, so it is not restored. Text of any realistic
    /// length is far below it; a large copied image may not be. The read stops at the first
    /// representation that crosses it, but that one representation is read in full — there is no
    /// way to ask its size first. Writing 32 MiB to a private pasteboard measured about 7 ms on
    /// the development Mac, and a restore does that write on the main actor.
    nonisolated static let defaultMaximumSnapshotBytes = 32 * 1024 * 1024

    /// The user's clipboard content this injector can put back, and how to tell it is still owed.
    private enum Held {
        /// Read at capture start, or just written back by a restore. Current while the
        /// pasteboard's `changeCount` equals `snapshot.changeCount`.
        case current(PasteboardSnapshot)
        /// A pasted dictation replaced it and a restore is scheduled. Still owed while the
        /// pasteboard's `changeCount` equals `written`, the count right after that dictation was
        /// written. `dictation` is what to put back if the restore fails after clearing.
        case displaced(PasteboardSnapshot, written: Int, dictation: String)

        var snapshot: PasteboardSnapshot {
            switch self {
            case let .current(snapshot), let .displaced(snapshot, _, _): snapshot
            }
        }
    }

    private let pasteboard: NSPasteboard
    private let restoreDelay: TimeInterval
    private let maximumSnapshotBytes: Int
    private let canSynthesizePaste: () -> Bool
    private let synthesizePaste: () -> Bool
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private let log = Logger(subsystem: "com.whispermeet.app", category: "dictation")

    private var held: Held?
    /// Bumped by every capture start and every delivery, so a read that reports back after either
    /// is discarded rather than mistaken for the current clipboard.
    private var snapshotGeneration = 0
    /// Bumped by every delivery, so a restore scheduled by an earlier paste does nothing once a
    /// later write has taken over the clipboard.
    private var restoreGeneration = 0
    /// Between a capture start and its delivery. A dictation that ends without delivering leaves
    /// this set, which only means a restore that fires afterwards keeps its snapshot held for the
    /// next dictation instead of dropping it.
    private var captureInFlight = false

    /// The off-main read `captureWillStart` began, if any — exposed so a test can await it
    /// reporting back instead of sleeping.
    private(set) var snapshotRead: Task<Void, Never>?

    /// One serial queue, so a read blocked on a slow promise (a phone that has gone out of range)
    /// makes the next dictation's read wait rather than pile a second blocked thread beside it.
    nonisolated private static let snapshotQueue = DispatchQueue(
        label: "com.whispermeet.dictation.clipboard-snapshot",
        qos: .userInitiated
    )

    init(
        pasteboard: NSPasteboard = .general,
        restoreDelay: TimeInterval = TextInjector.defaultRestoreDelay,
        maximumSnapshotBytes: Int = TextInjector.defaultMaximumSnapshotBytes,
        canSynthesizePaste: @escaping () -> Bool = { AXIsProcessTrusted() },
        synthesizePaste: @escaping () -> Bool = TextInjector.postCommandV,
        schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = TextInjector.scheduleOnMain
    ) {
        self.pasteboard = pasteboard
        self.restoreDelay = restoreDelay
        self.maximumSnapshotBytes = maximumSnapshotBytes
        self.canSynthesizePaste = canSynthesizePaste
        self.synthesizePaste = synthesizePaste
        self.schedule = schedule
    }

    /// Called when a dictation starts recording. Snapshots the clipboard now rather than at
    /// delivery because reading a promised representation — Universal Clipboard content may have
    /// to come from the other device — can block, and delivery runs on the main actor with the
    /// user waiting for their text. Here the read overlaps the user speaking.
    ///
    /// A clipboard the user changes while dictating is not re-read at delivery: that read would
    /// block the paste for the same reason. The snapshot is then stale, so nothing is restored.
    func captureWillStart(autoPaste: Bool) {
        snapshotGeneration &+= 1
        snapshotRead = nil
        captureInFlight = true
        if let held, isStillOwed(held) {
            // Either the clipboard still holds exactly the snapshot's content, or it holds the
            // previous dictation with that one's restore still to come. Reading now would, in the
            // second case, snapshot our own dictation and later "restore" it over the user's.
            return
        }
        held = nil
        guard autoPaste, canSynthesizePaste(), mayReadContents() else { return }
        let generation = snapshotGeneration
        let source = PasteboardHandle(pasteboard: pasteboard)
        let maximumBytes = maximumSnapshotBytes
        snapshotRead = Task { [weak self] in
            let outcome = await withCheckedContinuation { continuation in
                Self.snapshotQueue.async {
                    continuation.resume(
                        returning: PasteboardSnapshot.read(from: source.pasteboard, maximumBytes: maximumBytes)
                    )
                }
            }
            self?.snapshotDidFinish(outcome, generation: generation)
        }
    }

    @discardableResult
    func deliver(_ text: String, autoPaste: Bool) -> Delivery {
        snapshotGeneration &+= 1 // a read still in flight is too late for this delivery
        restoreGeneration &+= 1  // this write takes the clipboard over from any earlier paste
        captureInFlight = false
        // Decided before writing, because the write is what moves the change count.
        let owed = held.flatMap { isStillOwed($0) ? $0.snapshot : nil }
        held = nil

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let written = pasteboard.changeCount
        guard autoPaste, synthesizePaste() else {
            return .clipboard // no ⌘V: the clipboard is the delivery, so the dictation stays on it
        }
        guard let owed else { return .pasted }
        held = .displaced(owed, written: written, dictation: text)
        let generation = restoreGeneration
        schedule(restoreDelay) { [weak self] in self?.restoreIfUnchanged(generation: generation) }
        return .pasted
    }

    private func snapshotDidFinish(
        _ outcome: Result<PasteboardSnapshot, PasteboardSnapshot.Refusal>,
        generation: Int
    ) {
        guard generation == snapshotGeneration else { return }
        switch outcome {
        case let .success(snapshot):
            held = .current(snapshot)
        case let .failure(refusal):
            log.notice("clipboard not snapshotted for restore: \(refusal.rawValue, privacy: .public)")
        }
    }

    private func restoreIfUnchanged(generation: Int) {
        guard generation == restoreGeneration,
              case let .displaced(snapshot, written, dictation)? = held else { return }
        held = nil
        guard pasteboard.changeCount == written else {
            log.notice("clipboard not restored: it was written to after the dictation was pasted")
            return
        }
        guard let staged = snapshot.stagedItems() else {
            log.error("clipboard not restored: a saved representation was refused")
            return
        }
        pasteboard.clearContents()
        // An empty snapshot is an empty clipboard, which the clear above has already restored.
        guard staged.isEmpty || pasteboard.writeObjects(staged) else {
            // The clear already happened; put the dictation back rather than leave nothing.
            pasteboard.clearContents()
            pasteboard.setString(dictation, forType: .string)
            log.error("clipboard not restored: the pasteboard refused the saved items")
            return
        }
        // The pasteboard now holds the snapshot's content again. A dictation already under way
        // when this fired can still give it back after its own paste, so it stays held for that.
        held = captureInFlight ? .current(snapshot.current(at: pasteboard.changeCount)) : nil
        log.notice("clipboard restored after dictation paste")
    }

    private func isStillOwed(_ held: Held) -> Bool {
        switch held {
        case let .current(snapshot): pasteboard.changeCount == snapshot.changeCount
        case let .displaced(_, written, _): pasteboard.changeCount == written
        }
    }

    private func mayReadContents() -> Bool {
        if #available(macOS 15.4, *) {
            return Self.allowsSnapshot(accessBehavior: pasteboard.accessBehavior)
        }
        return true // no programmatic-access control exists before macOS 15.4
    }

    /// Whether to read the clipboard's contents for a snapshot, given the user's pasteboard access
    /// setting for this app.
    ///
    /// NSPasteboard.h: the general pasteboard's default "is to ask upon programmatic access", and
    /// only access that is "both user originated and paste related" is exempt. This read is
    /// neither — it happens when a dictation starts, not on a paste — so where the system applies
    /// that rule, the read can raise an alert while the user is dictating.
    ///
    /// - `.ask`: no — every read would raise the alert.
    /// - `.alwaysDeny`: no — the read would be refused, and what a refused read returns must not
    ///   be mistaken for an empty clipboard and "restored".
    /// - `.alwaysAllow`: yes — the user chose it.
    /// - `.default`: yes. The header says an app "that has never triggered a pasteboard access
    ///   alert" reports this. Where the system does not raise the alert, the read is silent and
    ///   the restore works; where it does, the first read raises it once, the header says the state
    ///   then becomes `.ask`, and no further read is attempted unless the user picks Always Allow.
    ///   I chose one possible alert over a restore that never works; skipping `.default` too would
    ///   be the choice if that alert is judged worse.
    @available(macOS 15.4, *)
    nonisolated static func allowsSnapshot(accessBehavior: NSPasteboard.AccessBehavior) -> Bool {
        switch accessBehavior {
        case .alwaysAllow, .default: true
        case .ask, .alwaysDeny: false
        @unknown default: false
        }
    }

    /// Synthesizes ⌘V into the focused app. False when it cannot: no Accessibility, or the events
    /// could not be created.
    nonisolated static func postCommandV() -> Bool {
        let vKey: CGKeyCode = 9 // kVK_ANSI_V
        guard AXIsProcessTrusted(),
              let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else {
            return false
        }

        // Let the pasteboard settle before the synthetic paste.
        usleep(20_000)

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }

    nonisolated static func scheduleOnMain(
        after delay: TimeInterval,
        _ work: @escaping @MainActor () -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { work() }
        }
    }
}

/// `NSPasteboard` is not `Sendable`, and the snapshot read hands one to a background queue.
/// NSPasteboard.h carries no main-thread or main-actor annotation, and says nothing either way
/// about use from two threads at once. That can happen: the main actor writes the same general
/// pasteboard when a delivery lands before the read finishes, and when the user presses one of
/// the app's own Copy buttons mid-dictation. The read cannot come back looking current after
/// that: an item made stale by the write returns nil (NSPasteboardItem.h), which reads as
/// `.incomplete`; a write between the read's two `changeCount` checks reads as
/// `.changedWhileReading`; and a write after both leaves a snapshot whose count no longer matches.
private struct PasteboardHandle: @unchecked Sendable {
    let pasteboard: NSPasteboard
}
