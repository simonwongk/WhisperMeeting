import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

private enum ExpectedFailure: Error {
    case finishingTrack
}

private final class CallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var healthUpdate = false
    private var levelsUpdate = false

    func recordHealthUpdate() {
        lock.withLock { healthUpdate = true }
    }

    func recordLevelsUpdate() {
        lock.withLock { levelsUpdate = true }
    }

    var receivedBothUpdates: Bool {
        lock.withLock { healthUpdate && levelsUpdate }
    }
}

@Test("A failed stop releases the capture session and preserves partial tracks")
func failedStopReleasesCaptureSession() async throws {
    var stopCount = 0
    var startCount = 0
    var preservedPartialTracks = false
    let callbacks = CallbackRecorder()
    let engine = AudioCaptureEngine(
        stoppingCapture: {
            stopCount += 1
        },
        finishingTracks: {
            throw ExpectedFailure.finishingTrack
        },
        preservingPartialTracks: {
            preservedPartialTracks = true
        },
        startingCapture: { _, onHealthUpdate, onLevels in
            startCount += 1
            onHealthUpdate(RecordingHealthSnapshot(
                microphoneLevel: .silent,
                systemAudioLevel: .silent,
                availableStorageBytes: nil,
                warnings: []
            ))
            onLevels(.silent)
        },
        directory: FileManager.default.temporaryDirectory
    )

    await #expect(throws: ExpectedFailure.self) {
        try await engine.stop()
    }

    try await engine.start(
        in: FileManager.default.temporaryDirectory,
        onHealthUpdate: { _ in callbacks.recordHealthUpdate() },
        onLevels: { _ in callbacks.recordLevelsUpdate() }
    )

    #expect(stopCount == 1)
    #expect(startCount == 1)
    #expect(preservedPartialTracks)
    #expect(callbacks.receivedBothUpdates)
}
