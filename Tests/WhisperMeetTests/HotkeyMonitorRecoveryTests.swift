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
