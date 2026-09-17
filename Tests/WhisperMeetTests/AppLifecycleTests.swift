import AppKit
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F257 — the app-lifecycle work moved off the window. These pin the parts that do not need a
// windowless launch to observe: that the subscriptions are taken once, that each notification
// flushes, and that startup recovery runs exactly once however many times it is asked.
//
// The physical half — close the window, record from the menu bar, force an alert-worthy condition,
// confirm the user is told — needs the app and is in `NEEDS_HUMAN.md`.

@MainActor
@Test("Startup recovery runs exactly once, however many times the lifecycle asks (F257)")
func startupRecoveryRunsOnce() async {
    // The reason this matters after moving the call: the delegate runs it at launch AND the window's
    // `.task` used to. If both remain, or if the delegate fires twice, recovery would re-run — and
    // `performStartupRecovery` rebuilds interrupted recordings, so running it twice is not free.
    let runs = Locked(0)
    let lifecycle = AppLifecycle()
    lifecycle.onStartupRecovery = { runs.withLock { $0 += 1 } }

    await lifecycle.runStartupRecoveryOnce()
    await lifecycle.runStartupRecoveryOnce()
    await lifecycle.runStartupRecoveryOnce()

    #expect(runs.withLock { $0 } == 1)
    #expect(lifecycle.didRunStartupRecovery)
}

@MainActor
@Test("Each lifecycle notification flushes pending writes (F257)")
func everyNotificationFlushes() {
    // `willTerminate` and `willResignActive` both flush today, from view modifiers that do not exist
    // when the window is closed — so quitting from the menu bar lost the last debounced edit (F138's
    // guarantee, silently unavailable in the state F257 is about).
    let flushes = Locked(0)
    let lifecycle = AppLifecycle()
    lifecycle.onFlush = { flushes.withLock { $0 += 1 } }

    lifecycle.begin()
    defer { lifecycle.end() }

    NotificationCenter.default.post(name: NSApplication.willResignActiveNotification, object: nil)
    NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)

    #expect(flushes.withLock { $0 } == 2)
}

@MainActor
@Test("Beginning twice does not double-subscribe (F257)")
func beginIsIdempotent() {
    // `App.body` is evaluated more than once, so anything wired from it must tolerate being wired
    // again — otherwise every re-evaluation adds an observer and one quit flushes N times.
    let flushes = Locked(0)
    let lifecycle = AppLifecycle()
    lifecycle.onFlush = { flushes.withLock { $0 += 1 } }

    lifecycle.begin()
    lifecycle.begin()
    lifecycle.begin()
    defer { lifecycle.end() }

    NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)

    #expect(flushes.withLock { $0 } == 1)
}

@MainActor
@Test("Ending drops the subscriptions (F257)")
func endStopsObserving() {
    let flushes = Locked(0)
    let lifecycle = AppLifecycle()
    lifecycle.onFlush = { flushes.withLock { $0 += 1 } }

    lifecycle.begin()
    lifecycle.end()
    NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)

    #expect(flushes.withLock { $0 } == 0)
}

/// A Sendable counter, since the handlers are closures.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body(&value)
    }
}
