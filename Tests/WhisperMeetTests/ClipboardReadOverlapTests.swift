import AppKit
import Foundation
import Testing
@testable import WhisperMeet

/// F657 — F601 starts the clipboard read on `TextInjector`'s snapshot queue when the dictation
/// starts. If that read has not finished by paste time — a lazily provided 12-megapixel image took
/// 2.5 s (F601's measurement), and a short dictation is shorter — the main thread used the same
/// `NSPasteboard` at the same time: a second read at paste time, then `clearContents` and
/// `writeObjects` while the queue was still inside `data(forType:)`. F425 never let the two meet.
///
/// The early read here is a fake that blocks until released, on a private pasteboard. A helper
/// thread releases it as soon as the main thread is seen touching the pasteboard (a second read, or
/// a write) — which is what the overlap looks like — or, when nothing overlaps, after half a second.
/// The half second only bounds how long a correct run waits; what is asserted — at most one read in
/// flight, and no write while the early read is inside — does not depend on it.

private final class BlockingReads: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var inFlight = 0
    private(set) var maxInFlight = 0
    private(set) var earlyEntered = false
    private(set) var laterEntered = false
    private(set) var writtenDuringEarlyRead = false
    private var countAtEarlyEntry = 0
    let release = DispatchSemaphore(value: 0)
    /// The pasteboard whose writes count as "during the early read": the one read, unless a test
    /// watches another — the restore test's second injector shares only the snapshot queue.
    private let watched: TextInjector.PasteboardHandle?

    init(watching watched: TextInjector.PasteboardHandle? = nil) {
        self.watched = watched
    }

    func snapshot() -> (maxInFlight: Int, earlyEntered: Bool, laterEntered: Bool, writtenDuringEarlyRead: Bool) {
        lock.withLock { (maxInFlight, earlyEntered, laterEntered, writtenDuringEarlyRead) }
    }

    var entryCount: Int { lock.withLock { countAtEarlyEntry } }

    func read(_ handle: TextInjector.PasteboardHandle, _ limit: Int) -> Result<PasteboardSnapshot, PasteboardSnapshot.Refusal> {
        let call: Int = lock.withLock {
            calls += 1
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
            if calls == 1 {
                earlyEntered = true
                countAtEarlyEntry = (watched ?? handle).pasteboard.changeCount
            } else {
                laterEntered = true
            }
            return calls
        }
        if call == 1 {
            release.wait()
            let moved = (watched ?? handle).pasteboard.changeCount != lock.withLock { countAtEarlyEntry }
            lock.withLock { if moved { writtenDuringEarlyRead = true } }
        }
        let result = PasteboardSnapshot.read(from: handle.pasteboard, maximumBytes: limit)
        lock.withLock { inFlight -= 1 }
        return result
    }
}

@MainActor
private final class OverlapHarness {
    let board = NSPasteboard.withUniqueName()
    let reads: BlockingReads
    /// What the release helper watches for a write: this harness's board unless told otherwise.
    private let watched: NSPasteboard?
    var textFieldFocused = true
    var frontmost: pid_t = 100
    var secure = false
    private(set) var pasteCount = 0

    init(watching watched: NSPasteboard? = nil) throws {
        self.watched = watched
        reads = BlockingReads(watching: watched.map { TextInjector.PasteboardHandle(pasteboard: $0) })
        board.clearContents()
        board.setString("copied on my phone", forType: .string)
        try #require(board.string(forType: .string) == "copied on my phone", "the private pasteboard does not round-trip a string on this host")
    }

    func makeInjector() -> TextInjector {
        let reads = self.reads
        return TextInjector(
            pasteboard: board,
            readSnapshot: { reads.read($0, $1) },
            canSynthesizePaste: { true },
            focusedTextField: { [unowned self] in
                FocusedTextField.Probe(
                    isTextField: self.textFieldFocused, summary: "test", processIdentifier: self.frontmost,
                    secureInput: self.secure ? .passwordField : nil
                )
            },
            synthesizePaste: { [unowned self] in
                self.pasteCount += 1
                return true
            },
            schedule: { _, _ in }
        )
    }

    /// Starts the early read and waits — on the read's own flag, capped — until it is inside the
    /// fake and blocked; then arms the helper that releases it.
    func startBlockedEarlyRead(_ injector: TextInjector) async throws -> (FocusedTextField.Probe, Task<Void, Never>) {
        let pressedIn = injector.captureWillStart(autoPaste: true)
        let early = try #require(injector.clipboardPrefetch, "the press did not start the early read")
        let deadline = Date().addingTimeInterval(30)
        while !reads.snapshot().earlyEntered, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(reads.snapshot().earlyEntered, "the early read never started")
        let reads = self.reads
        let handle = TextInjector.PasteboardHandle(pasteboard: watched ?? board)
        let start = reads.entryCount
        Thread.detachNewThread {
            let bound = Date().addingTimeInterval(0.5)
            while !reads.snapshot().laterEntered, handle.pasteboard.changeCount == start, Date() < bound {
                usleep(1_000)
            }
            reads.release.signal()
        }
        return (pressedIn, early)
    }

    deinit { board.releaseGlobally() }
}

@MainActor
@Test("The paste-time read waits for an early read still in flight, and never overlaps it (F657)")
func thePasteTimeReadWaitsForTheEarlyRead() async throws {
    let harness = try OverlapHarness()
    let injector = harness.makeInjector()
    let (pressedIn, early) = try await harness.startBlockedEarlyRead(injector)

    #expect(injector.deliver("dictated words", autoPaste: true, pressedIn: pressedIn) == .pasted)
    await early.value

    let seen = harness.reads.snapshot()
    #expect(seen.laterEntered, "no paste-time read happened, so this test checked nothing")
    #expect(seen.maxInFlight == 1)
    #expect(!seen.writtenDuringEarlyRead)
    #expect(harness.pasteCount == 1)
}

/// Since F656 this path drains the queue before its second look, so the drain — not `write`'s own
/// routing — is what this test now sees; the routing is pinned by the tests below.
@MainActor
@Test("A write at delivery waits for an early read still in flight (F657)")
func aWriteAtDeliveryWaitsForTheEarlyRead() async throws {
    let harness = try OverlapHarness()
    let injector = harness.makeInjector()
    let (pressedIn, early) = try await harness.startBlockedEarlyRead(injector)
    // Focus moved off the field while transcribing: no paste-time read, only the write.
    harness.textFieldFocused = false

    #expect(injector.deliver("dictated words", autoPaste: true, pressedIn: pressedIn) == .pastedUnconfirmed)
    await early.value

    let seen = harness.reads.snapshot()
    #expect(!seen.laterEntered)
    #expect(!seen.writtenDuringEarlyRead)
    #expect(harness.board.string(forType: .string) == "dictated words")
}

// MARK: - Write routing (lane J round-2 review: reverting either to the main thread failed no test)

/// The delivery's write with no drain before it: the app changed at the first look. Only `write`'s
/// own trip through the snapshot queue keeps it out of the early read.
@MainActor
@Test("A write for an app that changed waits for an early read still in flight (F657)")
func anAppChangedWriteWaitsForTheEarlyRead() async throws {
    let harness = try OverlapHarness()
    let injector = harness.makeInjector()
    let (pressedIn, early) = try await harness.startBlockedEarlyRead(injector)
    harness.frontmost = 200

    #expect(injector.deliver("dictated words", autoPaste: true, pressedIn: pressedIn) == .appChanged)
    await early.value

    let seen = harness.reads.snapshot()
    #expect(!seen.laterEntered)
    #expect(!seen.writtenDuringEarlyRead)
    #expect(harness.pasteCount == 0)
    #expect(harness.board.string(forType: .string) == "dictated words")
}

/// F586's Copy, reached the realistic way with a read in flight: a secure refusal at the first look
/// returns before any wait, leaving this dictation's early read running, and the user presses Copy
/// on the pill at once.
@MainActor
@Test("Copy from the secure pill waits for an early read still in flight (F657, F586)")
func copyFromTheSecurePillWaitsForTheEarlyRead() async throws {
    let harness = try OverlapHarness()
    let injector = harness.makeInjector()
    let (pressedIn, early) = try await harness.startBlockedEarlyRead(injector)
    harness.secure = true

    #expect(injector.deliver("dictated words", autoPaste: true, pressedIn: pressedIn) == .secureInput)
    injector.copyConcealed("dictated words")
    await early.value

    #expect(!harness.reads.snapshot().writtenDuringEarlyRead)
    #expect(harness.board.string(forType: .string) == "dictated words")
}

/// The restore. In the app a restore does not meet an early read — a press while one is owed reads
/// nothing early, and every delivery write waits for the queue — so this pins its routing with a
/// second injector, whose blocked read is on its own pasteboard and shares only the (static)
/// snapshot queue: the restore must wait for it like every other write.
@MainActor
@Test("The clipboard restore goes through the snapshot queue like every other write (F657)")
func theRestoreGoesThroughTheSnapshotQueue() async throws {
    let restoring = NSPasteboard.withUniqueName()
    defer { restoring.releaseGlobally() }
    restoring.clearContents()
    restoring.setString("copied on my phone", forType: .string)
    try #require(restoring.string(forType: .string) == "copied on my phone", "the private pasteboard does not round-trip a string on this host")
    var restores: [@MainActor () -> Void] = []
    let pasting = TextInjector(
        pasteboard: restoring,
        canSynthesizePaste: { true },
        focusedTextField: { FocusedTextField.Probe(isTextField: true, summary: "test", processIdentifier: 100) },
        synthesizePaste: { true },
        schedule: { _, work in restores.append(work) }
    )
    #expect(pasting.deliver("dictated words", autoPaste: true) == .pasted)
    try #require(restores.count == 1)

    let harness = try OverlapHarness(watching: restoring)
    let reading = harness.makeInjector()
    let (_, early) = try await harness.startBlockedEarlyRead(reading)
    restores[0]()
    await early.value

    #expect(!harness.reads.snapshot().writtenDuringEarlyRead)
    #expect(restoring.string(forType: .string) == "copied on my phone")
}
