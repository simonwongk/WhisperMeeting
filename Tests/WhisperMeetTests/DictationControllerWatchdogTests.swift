import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

// Shared headless fakes live in DictationTestSupport.swift.

/// Polls `condition` every 5 ms under a 30 s cap and requires it, so a timeout fails as a timeout (F639).
@MainActor
private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    var ticks = 0
    while !condition(), ticks < 6_000 {
        try await Task.sleep(nanoseconds: 5_000_000)
        ticks += 1
    }
    try #require(condition(), "timed out waiting for \(what)")
}

@MainActor
@Test("A missed dictation release stops recording and recovers the controller to idle")
func missedReleaseRecoversController() async throws {
    let suite = "WhisperMeet.DictationControllerWatchdogTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationControllerWatchdogTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: temporaryDirectory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    defaults.set(true, forKey: "dictationEnabled")
    defaults.set(false, forKey: "dictationAutoPaste")

    let recorder = FakeDictationRecorder(
        outputURL: temporaryDirectory.appendingPathComponent("capture.wav")
    )
    let controller = DictationController(
        defaults: defaults,
        engine: EmptyDictationEngine(),
        recorder: recorder,
        overlay: SilentDictationOverlay(),
        logStore: DictationLogStore(directory: temporaryDirectory),
        captureTimeout: .seconds(120),
        captureSleep: { _ in },
        textInjector: isolatedTextInjector(),
        activateOnInit: false
    )

    controller.handlePressStart()
    // Polls the recovery itself under a wall-clock cap, never a 20-yield count (F639): the count
    // expires under a starved scheduler before the watchdog task has run, and would then fail the
    // three assertions below as claims about the controller. The stop is part of the wait's
    // condition, so seeing `.idle` before the capture was stopped does not end it.
    try await waitUntil("the controller to stop the capture and recover to idle") {
        recorder.stopCount >= 1 && controller.status == .idle
    }

    #expect(recorder.stopCount == 1)
    #expect(!recorder.isRecording)
    #expect(controller.status == .idle)
}
