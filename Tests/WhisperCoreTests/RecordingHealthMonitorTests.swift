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

@Test("Overall status is good while both channels are captured with no warnings")
func reportsGoodStatusWhenHealthy() {
    let monitor = RecordingHealthMonitor(startedAt: 100)
    monitor.receive(.microphone, level: .init(rms: 0.2, peak: 0.4), at: 101)
    monitor.receive(.systemAudio, level: .init(rms: 0.1, peak: 0.3), at: 101)

    let snapshot = monitor.snapshot(at: 102, availableStorageBytes: 20_000_000_000)

    #expect(snapshot.warnings.isEmpty)
    #expect(snapshot.overallStatus == .good)
}

@Test("Clipping is a caution, while a stopped channel or low storage is at-risk")
func mapsWarningSeverityToStatus() {
    let clipping = RecordingHealthSnapshot(
        microphoneLevel: .init(rms: 0.6, peak: 1),
        systemAudioLevel: .silent,
        availableStorageBytes: 20_000_000_000,
        warnings: [.microphoneClipping]
    )
    #expect(clipping.overallStatus == .caution)

    let notDetected = RecordingHealthSnapshot(
        microphoneLevel: .init(rms: 0.2, peak: 0.4),
        systemAudioLevel: .silent,
        availableStorageBytes: 20_000_000_000,
        warnings: [.systemAudioNotDetected]
    )
    #expect(notDetected.overallStatus == .caution)

    let stopped = RecordingHealthSnapshot(
        microphoneLevel: .silent,
        systemAudioLevel: .silent,
        availableStorageBytes: 20_000_000_000,
        warnings: [.microphoneCaptureStopped]
    )
    #expect(stopped.overallStatus == .atRisk)

    let lowStorage = RecordingHealthSnapshot(
        microphoneLevel: .init(rms: 0.2, peak: 0.4),
        systemAudioLevel: .init(rms: 0.1, peak: 0.3),
        availableStorageBytes: 1_000_000_000,
        warnings: [.lowStorage]
    )
    #expect(lowStorage.overallStatus == .atRisk)
}

@Test("Conversational microphone audio uses a calibrated perceptual meter scale")
func calibratesConversationalMicrophoneLevel() {
    var meter = RecordingLevelMeter()
    meter.receive(
        .microphone,
        level: RecordingAudioLevel(rms: 0.04, peak: 0.17),
        at: 100
    )

    let snapshot = meter.snapshot(at: 100)

    #expect(snapshot.microphone > 0.4)
    #expect(snapshot.microphone < 0.9)
    #expect(snapshot.combined == snapshot.microphone)
    #expect(snapshot.isSpeaking)
    #expect(snapshot.microphoneActive)
    #expect(!snapshot.systemAudioActive)
}

@Test("A channel that stops producing samples decays to silence")
func expiresStaleRecordingLevel() {
    var meter = RecordingLevelMeter()
    meter.receive(
        .microphone,
        level: RecordingAudioLevel(rms: 0.08, peak: 0.3),
        at: 100
    )
    _ = meter.snapshot(at: 100)
    _ = meter.snapshot(at: 100.4)

    let expired = meter.snapshot(at: 102)

    #expect(expired.microphone < 0.01)
    #expect(!expired.isSpeaking)
    #expect(!expired.microphoneActive)
}
