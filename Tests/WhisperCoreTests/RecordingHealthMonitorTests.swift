import Testing
@testable import WhisperCore

@Test("A recording warns when a capture channel stops delivering samples")
func warnsWhenCaptureChannelStops() {
    let monitor = RecordingHealthMonitor(startedAt: 100)

    monitor.receive(.microphone, level: .init(rms: 0.2, peak: 0.4), at: 101)
    monitor.receive(.systemAudio, level: .init(rms: 0.1, peak: 0.3), at: 101)

    let snapshot = monitor.snapshot(at: 106, availableStorageBytes: 20_000_000_000)

    #expect(snapshot.warnings.contains(.microphoneCaptureStopped))
    #expect(snapshot.warnings.contains(.systemAudioCaptureStopped))
}

@Test("A recording warns when either channel clips")
func warnsWhenCapturedAudioClips() {
    let monitor = RecordingHealthMonitor(startedAt: 100)

    monitor.receive(.microphone, level: .init(rms: 0.7, peak: 0.995), at: 101)
    monitor.receive(.systemAudio, level: .init(rms: 0.6, peak: 1), at: 101)

    let snapshot = monitor.snapshot(at: 102, availableStorageBytes: 20_000_000_000)

    #expect(snapshot.warnings.contains(.microphoneClipping))
    #expect(snapshot.warnings.contains(.systemAudioClipping))
}

@Test("A recording warns before local storage becomes critically low")
func warnsWhenStorageIsLow() {
    let monitor = RecordingHealthMonitor(startedAt: 100)
    monitor.receive(.microphone, level: .silent, at: 101)
    monitor.receive(.systemAudio, level: .silent, at: 101)

    let snapshot = monitor.snapshot(at: 102, availableStorageBytes: 1_500_000_000)

    #expect(snapshot.warnings.contains(.lowStorage))
}

@Test("A silent start does not falsely claim that system capture stopped")
func distinguishesUndetectedSystemAudioFromStoppedCapture() {
    let monitor = RecordingHealthMonitor(startedAt: 100)
    monitor.receive(.microphone, level: .silent, at: 116)

    let snapshot = monitor.snapshot(at: 116, availableStorageBytes: 20_000_000_000)

    #expect(snapshot.warnings.contains(.systemAudioNotDetected))
    #expect(!snapshot.warnings.contains(.systemAudioCaptureStopped))
}
