import CoreGraphics
import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

private final class PressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    var value: Int {
        lock.withLock { count }
    }
}

@MainActor
@Test("A disabled event tap resynchronizes a missed F-key release")
func disabledTapResynchronizesFKeyState() async throws {
    let presses = PressCounter()
    let monitor = HotkeyMonitor(
        hotkey: DictationHotkey(keyCode: 96, mode: .hold),
        currentKeyState: { _ in false }
    )
    monitor.onPressStart = presses.increment

    monitor.handleKeyStateChange(true)
    try await Task.sleep(for: .milliseconds(10))
    monitor.recoverFromDisabledTap()
    monitor.handleKeyStateChange(true)
    try await Task.sleep(for: .milliseconds(10))

    #expect(presses.value == 2)
}

/// Counts both edges the monitor dispatches. Lock-guarded: the monitor dispatches on the main queue.
private final class EdgeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var ends = 0

    func start() { lock.withLock { starts += 1 } }
    func end() { lock.withLock { ends += 1 } }
    var startCount: Int { lock.withLock { starts } }
    var endCount: Int { lock.withLock { ends } }
}

/// The monitor dispatches every edge with `DispatchQueue.main.async`. The main queue is FIFO, so a
/// block enqueued after them runs after them: no clock involved.
@MainActor
private func drainMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

@MainActor
@Test("A release the disabled tap missed is dispatched when the tap recovers (F446)")
func disabledTapDispatchesTheMissedRelease() async {
    let edges = EdgeCounter()
    let monitor = HotkeyMonitor(
        hotkey: DictationHotkey(keyCode: 96, mode: .hold),
        currentKeyState: { _ in false } // released while the tap was disabled
    )
    monitor.onPressStart = edges.start
    monitor.onPressEnd = edges.end

    monitor.handleKeyStateChange(true) // held while the tap was live: the dictation starts
    monitor.recoverFromDisabledTap()
    await drainMainQueue()

    #expect(edges.startCount == 1)
    // Resynchronising the state without dispatching left a hold-mode capture running to the 120 s
    // watchdog and then pasting.
    #expect(edges.endCount == 1)
}

@MainActor
@Test("A trigger re-armed while its key is held still reports the release (F446)")
func rearmingAHeldTriggerKeepsItsRelease() async {
    let edges = EdgeCounter()
    let monitor = HotkeyMonitor(hotkey: .rightOption, currentKeyState: { _ in true })
    monitor.onPressStart = edges.start
    monitor.onPressEnd = edges.end

    monitor.handleKeyStateChange(true)
    // What `start(hotkey:)` does when Settings' "Change" hears the trigger key itself.
    monitor.adopt(.rightOption)
    monitor.handleKeyStateChange(false)
    await drainMainQueue()

    #expect(edges.startCount == 1)
    #expect(edges.endCount == 1)
}

@MainActor
@Test("Changing a toggle trigger while dictation is on keeps it on, so the new key turns it off (F446)")
func changingAToggleTriggerKeepsDictationOn() async {
    let edges = EdgeCounter()
    let monitor = HotkeyMonitor(
        hotkey: DictationHotkey(keyCode: 96, mode: .toggle),
        currentKeyState: { _ in false }
    )
    monitor.onPressStart = edges.start
    monitor.onPressEnd = edges.end

    monitor.handleKeyStateChange(true)
    monitor.handleKeyStateChange(false)
    monitor.adopt(DictationHotkey(keyCode: 97, mode: .toggle))
    monitor.handleKeyStateChange(true)
    await drainMainQueue()

    #expect(edges.startCount == 1)
    #expect(edges.endCount == 1)
}
