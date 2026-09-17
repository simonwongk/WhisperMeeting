import AppKit
import Foundation

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
    }
}
