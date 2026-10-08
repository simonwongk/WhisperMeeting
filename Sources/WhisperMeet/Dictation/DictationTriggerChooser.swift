import AppKit
import WhisperCore

/// Settings ▸ Quick Dictation ▸ Change: choosing a new trigger key.
///
/// Which key the user meant is `DictationTriggerCapture`'s question (F521); this owns everything
/// around it — the two event monitors, the "Press a key…" state, the hint, and setting the chosen
/// key. It used to be `@State` and two functions in `SettingsView`, where nothing could test when a
/// choice ends.
///
/// Two monitors, both removed by `end()`. The local one hears keys, modifier changes and clicks in
/// this app: keys only from the window whose Change button was pressed — in the main window's
/// Settings pane the toolbar search shares that window, which the capture's own rules cover — and
/// clicks from any window, since a ⌘-click in the main window while Settings has the key is still a
/// modifier held for a click (F653). The global one hears mouse-downs in other apps, which needs no
/// permission: a ⌘-click on another app's window can leave WhisperMeet frontmost, so the ⌘'s release
/// still arrives here. Keys the rules pass on reach the app as usual, so ⌘W still closes the window,
/// and Escape cancels.
///
/// A choice ends however the user leaves it (F691): Change again, a key chosen, Escape, Settings
/// going away (`end()` from its `.onDisappear`), its window closing, or WhisperMeet going to the
/// background. It used not to end in the background, and until the user came back the global
/// monitor observed — and discarded — every click in every other app. A plain click in another app
/// makes that app active and so ends the choice; F653's ⌘-click on another app's window leaves
/// WhisperMeet in front and is still heard. The window is watched as well as `.onDisappear`, because
/// whether SwiftUI calls that when a Settings window closes has never been checked on screen.
@MainActor
final class DictationTriggerChooser: ObservableObject {
    /// A key is being chosen; the Change button reads "Press a key…".
    @Published private(set) var isChoosing = false
    /// Why the last key pressed cannot be a trigger (F521), shown under the trigger row.
    @Published private(set) var hint: String?

    /// How the chooser hears events. The defaults are `NSEvent`'s; a test counts monitors instead,
    /// with no window and no keyboard.
    struct EventMonitors {
        var addLocal: (NSEvent.EventTypeMask, @escaping (NSEvent) -> NSEvent?) -> Any?
        var addGlobal: (NSEvent.EventTypeMask, @escaping (NSEvent) -> Void) -> Any?
        var remove: (Any) -> Void

        static let system = EventMonitors(
            addLocal: { NSEvent.addLocalMonitorForEvents(matching: $0, handler: $1) },
            addGlobal: { NSEvent.addGlobalMonitorForEvents(matching: $0, handler: $1) },
            remove: { NSEvent.removeMonitor($0) }
        )
    }

    private let monitors: EventMonitors
    /// Where WhisperMeet going to the background and the window closing are heard (F691).
    private let notifications: NotificationCenter
    private var capture = DictationTriggerCapture()
    private var keyMonitor: Any?
    /// Clicks in other apps while choosing, which the local monitor cannot see (F653).
    private var clickMonitor: Any?
    /// The observers that end a choice when WhisperMeet goes to the background or its window
    /// closes (F691), held only while choosing.
    private var endObservers: [NSObjectProtocol] = []
    private weak var dictation: DictationController?

    init(monitors: EventMonitors = .system, notifications: NotificationCenter = .default) {
        self.monitors = monitors
        self.notifications = notifications
    }

    /// The Change button: starts choosing in `window` — the window the click (or Space) that
    /// pressed Change made key — or, while choosing, stops.
    func toggle(in window: AnyObject?, for dictation: DictationController) {
        if isChoosing { end(); return }
        guard let window else { return }
        begin(in: window, for: dictation)
    }

    private func begin(in window: AnyObject, for dictation: DictationController) {
        isChoosing = true
        hint = nil
        capture = DictationTriggerCapture()
        self.dictation = dictation
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        keyMonitor = monitors.addLocal(clicks.union([.keyDown, .flagsChanged])) { [weak self] event in
            guard let self else { return event }
            // F653: a click anywhere makes a modifier held for it — ⌘-click, ⌥-click — half of a
            // chord, not a lone press to choose. The click itself is the app's.
            if clicks.contains(NSEvent.EventTypeMask(type: event.type)) {
                self.receive(.click)
                return event
            }
            guard event.window === window else { return event }
            let input: DictationTriggerCapture.Input = event.type == .flagsChanged
                ? .modifiersChanged(keyCode: event.keyCode, flags: UInt64(event.modifierFlags.rawValue))
                : .keyDown(
                    keyCode: event.keyCode,
                    isShortcut: !event.modifierFlags.intersection([.command, .control]).isEmpty
                )
            return self.receive(input) ? event : nil
        }
        clickMonitor = monitors.addGlobal(clicks) { [weak self] _ in
            self?.receive(.click)
        }
        // F691. AppKit posts both on the main thread; the hop covers anything that posts them from
        // elsewhere, as `DictationController`'s activation observer does.
        let endChoice: @Sendable (Notification) -> Void = { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.end() }
            } else {
                Task { @MainActor in self?.end() }
            }
        }
        endObservers = [
            notifications.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: nil, using: endChoice
            ),
            notifications.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: nil, using: endChoice
            ),
        ]
    }

    /// One event while choosing, by `DictationTriggerCapture`'s rules (F521). Returns whether the
    /// event goes on to the app. Internal so a test can choose a key without a window.
    @discardableResult
    func receive(_ input: DictationTriggerCapture.Input) -> Bool {
        guard isChoosing else { return true }
        switch capture.handle(input) {
        case let .choose(code):
            if let dictation {
                dictation.hotkey = DictationHotkey(keyCode: code, mode: dictation.hotkey.mode)
            }
            end()
            // A modifier's release is let through, so the app's modifier state stays true.
            if case .modifiersChanged = input { return true }
            return false
        case .cancel:
            end()
            return false
        case .refuse:
            hint = DictationTriggerCapture.refusalHint
            return false
        case .pass:
            return true
        }
    }

    /// Stops choosing: both monitors go, and the observers that would end it. Safe to call when not
    /// choosing.
    func end() {
        for observer in endObservers { notifications.removeObserver(observer) }
        endObservers = []
        if let keyMonitor {
            monitors.remove(keyMonitor)
            self.keyMonitor = nil
        }
        if let clickMonitor {
            monitors.remove(clickMonitor)
            self.clickMonitor = nil
        }
        if isChoosing { isChoosing = false }
        if hint != nil { hint = nil }
    }
}
