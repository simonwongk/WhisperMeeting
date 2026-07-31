import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

// Shared headless fakes live in DictationTestSupport.swift.

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
        activateOnInit: false
    )

    controller.handlePressStart()
    for _ in 0..<20 where controller.status != .idle {
        await Task.yield()
    }

    #expect(recorder.stopCount == 1)
    #expect(!recorder.isRecording)
    #expect(controller.status == .idle)
}
