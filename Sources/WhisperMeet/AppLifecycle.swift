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
                ) { [weak self] _ in
                    // `assumeIsolated` rather than a `Task`, for the reason F253 documents: on
                    // `willTerminate` the process is going away and a hop would return before the
                    // flush ran. `queue: .main` makes the assumption true.
                    MainActor.assumeIsolated { self?.onFlush?() }
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
