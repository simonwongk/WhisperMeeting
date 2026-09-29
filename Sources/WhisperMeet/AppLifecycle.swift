import AppKit
import Foundation
import WhisperCore

/// The app's lifecycle work, owned by the process rather than by a window (F257).
///
/// **Why this exists.** `grep -rn "onReceive(NotificationCenter" Sources/` used to return exactly
/// two hits, both modifiers on `ContentView` inside the `WindowGroup`, and
/// `performStartupRecovery()` was a `.task` on that same view. The app nevertheless stays alive with
/// no window via `MenuBarExtra`, whose menu offers Start, Stop & Transcribe, Add Marker, Cancel and
/// Quit — so recording from the menu bar with the window closed meant no `willTerminate` flush on
/// quit and no startup-recovery summary, and the `.alert` host was gone too.
///
/// A class with injected closures rather than an `NSApplicationDelegate` subclass doing the work
/// itself: the delegate cannot be constructed in a test, and the behaviour worth pinning — subscribe
/// once, flush on each notification, recover exactly once — has nothing to do with AppKit.
@MainActor
public final class AppLifecycle: ObservableObject {
    // `ObservableObject` with nothing `@Published`: it publishes no state and no view observes it.
    // The conformance is for `@StateObject`, which is what guarantees ONE instance for the App's
    // lifetime — and that matters, because `begin()`'s idempotence is per instance, so two
    // lifecycles would each take their own observers and one quit would flush twice.
    /// Flush pending debounced writes. Called on resign-active and on terminate (F138).
    public var onFlush: (() -> Void)?

    /// Called once on terminate only, before `onFlush` (F520): stop running model installs, which
    /// would otherwise keep downloading headless after the app is gone.
    public var onTerminate: (() -> Void)?

    /// Run startup recovery. Called once per launch, whatever the window state.
    public var onStartupRecovery: (() async -> Void)?

    /// Whether startup recovery has already run in this process.
    public private(set) var didRunStartupRecovery = false

    // MARK: - Files handed over from outside (F181)

    /// Import these files. Set by the `App`; files that arrive before it is set, or before startup
    /// recovery has finished, wait in `pendingFiles`.
    public var onOpenFiles: (([URL]) async -> Void)? {
        didSet { Task { await deliverPendingFiles() } }
    }

    private var pendingFiles: [URL] = []
    private var didFinishStartupRecovery = false
    private var isDelivering = false

    /// Accepts files from Finder "Open With", the Dock, Shortcuts' "Open File" or the Finder
    /// service. Anything the importer cannot read is dropped here, before it can raise an error
    /// about a PDF the user never meant to transcribe.
    /// Told when an open contained nothing the importer can read (F344). A *mixed* drop stays
    /// silent about its rejects — the readable ones are being imported, which is the answer — but an
    /// explicit "Open With" on one PDF used to do nothing at all, visibly.
    public var onRejectedFiles: (([URL]) -> Void)?

    public func open(_ urls: [URL]) {
        let sorted = ExternalFileIntake.sort(urls)
        pendingFiles.append(contentsOf: sorted.importable)
        if sorted.importable.isEmpty, !sorted.rejected.isEmpty {
            onRejectedFiles?(sorted.rejected)
        }
        Task { await deliverPendingFiles() }
    }

    /// Hands waiting files to the importer once it is safe to: a launch *caused by* opening a file
    /// delivers the file before anything else has run, and importing ahead of startup recovery
    /// could index a new meeting while recovery is still deciding what the library holds.
    /// Drains rather than bails: an import takes seconds, and a second drop on the Dock while the
    /// first is importing used to append to `pendingFiles`, hit the `isDelivering` guard, and sit
    /// there until some later unrelated `open()` happened to flush it — so the second drag appeared
    /// to do nothing at all (F322).
    public func deliverPendingFiles() async {
        guard didFinishStartupRecovery, !isDelivering, !pendingFiles.isEmpty, let onOpenFiles else { return }
        isDelivering = true
        defer { isDelivering = false }
        while !pendingFiles.isEmpty {
            let batch = pendingFiles
            pendingFiles.removeAll()
            await onOpenFiles(batch)
        }
    }

    private var observers: [NSObjectProtocol] = []

    public init() {}

    /// Subscribes to the app-level notifications. Idempotent.
    ///
    /// Idempotence is required, not tidy: this is wired from a place `App.body` can evaluate more
    /// than once, and without the guard every re-evaluation would add an observer — so one quit
    /// would flush N times, each flush racing the others through the same debounced writer.
    public func begin() {
        guard observers.isEmpty else { return }
        for name in [
            NSApplication.willTerminateNotification,
            NSApplication.willResignActiveNotification,
        ] {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] notification in
                    // `assumeIsolated` rather than a `Task`, for the reason F253 documents: on
                    // `willTerminate` the process is going away and a hop would return before the
                    // flush ran. `queue: .main` makes the assumption true.
                    let isTerminating = notification.name == NSApplication.willTerminateNotification
                    MainActor.assumeIsolated {
                        if isTerminating { self?.onTerminate?() }
                        self?.onFlush?()
                    }
                }
            )
        }
    }

    /// Drops the subscriptions. For tests and for symmetry; a live app never needs it.
    public func end() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    /// Runs startup recovery unless it has already run in this process.
    ///
    /// The guard is load-bearing rather than defensive: `performStartupRecovery` rebuilds
    /// interrupted recordings and backfills sidecars, so a second run is real work over the user's
    /// library. `AppModel` has its own `didPerformStartupRecovery` flag, which F193 resets
    /// deliberately after a library restore — so this cannot rely on that one, and holds its own.
    public func runStartupRecoveryOnce() async {
        guard !didRunStartupRecovery else { return }
        didRunStartupRecovery = true
        await onStartupRecovery?()
        didFinishStartupRecovery = true
        await deliverPendingFiles()
    }

    // MARK: - Quitting during a recording (F529)

    /// The user's answer to "Stop and save the recording before quitting?".
    public enum QuitDuringRecordingChoice: Sendable, Equatable {
        case stopAndQuit
        case keepRecording
    }

    /// Whether a capture is running right now, so that quitting would cut a meeting short.
    public var isRecordingLive: (() -> Bool)?

    /// Whether a stop is already saving the recording — the user's own Stop, or one the app began
    /// for a sleep or a lost capture (F672).
    public var isRecordingFinishing: (() -> Bool)?

    /// Asks the user what to do about the live recording. Called only while `isRecordingLive`.
    public var confirmQuitDuringRecording: (() -> QuitDuringRecordingChoice)?

    /// Stops the live recording and saves it as a meeting. Returns whether the app may quit now.
    public var onStopRecordingForQuit: (() async -> Bool)?

    /// True from a "Stop & Quit" until its one reply has been sent.
    public private(set) var isStoppingForQuit = false
    /// True while the question is on screen.
    private var isAskingAboutQuit = false

    /// Decides a quit (⌘Q, the menu bar's Quit, Dock ▸ Quit, a logout): the answer
    /// `applicationShouldTerminate` gives AppKit. `reply` is `NSApp.reply(toApplicationShouldTerminate:)`.
    ///
    /// There was no such hook before F529, so every quit ended a live recording on the spot — no
    /// question, no `stopRecording`, the meeting left for the next launch to rebuild as an
    /// interrupted folder — while Cancel, which also cuts a meeting short, is confirmed twice.
    ///
    /// **Every `.terminateLater` gets exactly one `reply`, and nothing else gets one.** AppKit
    /// waits for that reply with the run loop in modal-panel mode, so a path that forgets it leaves
    /// an app that neither quits nor behaves normally. Hence the shape: the question is answered
    /// synchronously, so "Keep Recording" is a plain `.terminateCancel`; only "Stop & Quit" — and a
    /// quit that finds a stop already saving (F672) — goes asynchronous, and its task replies once,
    /// after the stop, whatever the stop returned. A quit that arrives while the question is up, or
    /// while that stop is still saving, is refused outright rather than asked or answered twice.
    ///
    /// A quit during `.starting` still terminates at once: nothing has been captured yet, and
    /// `stopRecording` itself refuses a stop until the capture is live.
    public func shouldTerminate(reply: @escaping (Bool) -> Void) -> NSApplication.TerminateReply {
        // The pending decision already answers for this quit; a second `reply` would answer a
        // question AppKit is no longer asking.
        // Likewise while the question is still on screen: the alert runs modally inside this call,
        // and a second quit reaching it would stack a second alert on the first.
        guard !isStoppingForQuit, !isAskingAboutQuit else { return .terminateCancel }
        // F672: a stop is already saving the recording — the user pressed Stop, or the app began one
        // for a sleep or a lost capture. There is nothing to ask, since the recording is already
        // ending, but `.terminateNow` here killed that save midway and left the meeting for the next
        // launch to rebuild. So it takes the same single-reply path as Stop & Quit, whose stop
        // (`AppModel.stopRecordingBeforeQuit`) waits for the one under way instead of starting one.
        if isRecordingFinishing?() == true { return stopThenReply(reply) }
        guard isRecordingLive?() == true else { return .terminateNow }
        isAskingAboutQuit = true
        // Unwired means a wiring bug, not a user who wants to keep recording: saving and quitting is
        // the answer that neither loses the meeting nor traps the user in an app that will not quit.
        let choice = confirmQuitDuringRecording?() ?? .stopAndQuit
        isAskingAboutQuit = false
        guard choice == .stopAndQuit else { return .terminateCancel }
        return stopThenReply(reply)
    }

    /// The one asynchronous path: stop (or wait for the stop under way), then reply exactly once.
    private func stopThenReply(_ reply: @escaping (Bool) -> Void) -> NSApplication.TerminateReply {
        isStoppingForQuit = true
        Task { @MainActor [weak self] in
            // No `onStopRecordingForQuit` means nothing to wait for. A `false` cancels the quit: the
            // stop could not save the meeting, and its message must outlive this process. The folder
            // is kept, so the next quit loses nothing a launch cannot rebuild.
            let mayQuit = await self?.onStopRecordingForQuit?() ?? true
            self?.isStoppingForQuit = false
            reply(mayQuit)
        }
        return .terminateLater
    }
}

/// The question F529 asks before a quit ends a live recording.
///
/// AppKit, so it is not part of the tested `AppLifecycle`: the choice it returns is the seam, and
/// `QuitDuringRecordingTests` drives every answer through `AppLifecycle.shouldTerminate`.
@MainActor
enum QuitDuringRecordingAlert {
    static let message = "Stop and save the recording before quitting?"
    static let information = "WhisperMeet is recording. Stop & Quit saves what has been recorded so far as a meeting, then quits. Keep Recording leaves WhisperMeet open and recording."
    static let stopAndQuitTitle = "Stop & Quit"
    static let keepRecordingTitle = "Keep Recording"

    /// Asks, modally. Keep Recording is the default button: the case F529 exists for is a ⌘Q
    /// pressed by mistake mid-call, and a Return pressed by the same reflex must not end the meeting.
    static func ask() -> AppLifecycle.QuitDuringRecordingChoice {
        // A Dock or menu-bar Quit arrives while another app is frontmost; the question has to be
        // where the user is looking.
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = information
        // The first button added is the rightmost and the default (Return).
        alert.addButton(withTitle: keepRecordingTitle)
        alert.addButton(withTitle: stopAndQuitTitle)
        return alert.runModal() == .alertSecondButtonReturn ? .stopAndQuit : .keepRecording
    }
}

/// Bridges `NSApplication`'s launch to `AppLifecycle`, because SwiftUI offers no scene-independent
/// place to run once (F257).
///
/// `applicationDidFinishLaunching` fires whether or not a window opens, which is the whole point:
/// a login-item launch, or a launch whose window the user closes immediately, still gets its
/// startup recovery and still flushes on quit.
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    /// Set by the `App` before the scene phase; read on launch.
    @MainActor static var lifecycle: AppLifecycle?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let lifecycle = Self.lifecycle else { return }
            lifecycle.begin()
            Task { await lifecycle.runStartupRecoveryOnce() }
        }
        // F181: publishes "Transcribe with WhisperMeet" (declared under NSServices in Info.plist).
        NSApp.servicesProvider = self
    }

    /// ⌘Q, the menu bar's "Quit WhisperMeet", Dock ▸ Quit and a logout all arrive here (F529).
    /// Without a lifecycle there is no recording to protect, so the quit goes ahead as it always did.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let lifecycle = Self.lifecycle else { return .terminateNow }
            return lifecycle.shouldTerminate { quit in
                NSApp.reply(toApplicationShouldTerminate: quit)
            }
        }
    }

    /// Finder "Open With", a drop on the Dock icon, and Shortcuts' "Open File" all arrive here (F181).
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { Self.pendingOrLive(urls) }
    }

    /// The Finder service's message, `transcribeFiles` in Info.plist (F181).
    @objc func transcribeFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        MainActor.assumeIsolated { Self.pendingOrLive(urls) }
    }

    /// A launch caused by opening a file calls the delegate before the `App` has published its
    /// lifecycle, so those files are parked here and picked up when it does.
    @MainActor private static var filesBeforeLifecycle: [URL] = []

    @MainActor private static func pendingOrLive(_ urls: [URL]) {
        if let lifecycle { lifecycle.open(urls) } else { filesBeforeLifecycle.append(contentsOf: urls) }
    }

    /// Called by the `App` right after it sets `lifecycle`.
    @MainActor static func flushFilesOpenedBeforeLaunchFinished() {
        guard let lifecycle, !filesBeforeLifecycle.isEmpty else { return }
        lifecycle.open(filesBeforeLifecycle)
        filesBeforeLifecycle.removeAll()
    }
}
