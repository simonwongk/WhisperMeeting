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

// MARK: - F150: warning before the WAV length field runs out

@Test("A recording approaching the WAV length limit is warned about (F150)")
func approachingWavLimitWarns() {
    // `meeting.wav` is 48 kHz mono 16-bit, so the `UInt32` `data`-chunk size runs out at
    // 4,294,967,295 / 96,000 ≈ 44,739 s ≈ 12 h 25 m. Past that the samples are still written, but a
    // strict reader — ffmpeg among them — honours the declared size and ignores everything beyond
    // ~4 GB. So the recording looks truncated when exported or re-transcribed, while being complete
    // on disk.
    //
    // F150's fix options are segmenting or RF64; this is its "at minimum warn near the limit", and
    // it is the part that needs no 12-hour recording to verify. The warning fires with time to act:
    // a user who is told at 11 h 55 m can stop and start a second recording, which is the outcome
    // segmenting would have produced automatically.
    let monitor = RecordingHealthMonitor(startedAt: 0)
    let warned = RecordingHealthMonitor.approachingLengthLimit(
        elapsedSeconds: RecordingHealthMonitor.wavLengthLimitSeconds
            - RecordingHealthMonitor.lengthLimitWarningLeadSeconds
    )
    #expect(warned)
    #expect(!RecordingHealthMonitor.approachingLengthLimit(elapsedSeconds: 3_600))
    #expect(RecordingHealthMonitor.approachingLengthLimit(elapsedSeconds: 1e9),
            "past the limit is still worth warning about, not silently fine")
    _ = monitor
}

@Test("The limit is derived from the header's own arithmetic, not a magic number (F150)")
func lengthLimitIsDerived() {
    // 16-bit mono at 48 kHz is 96,000 bytes per second, and the field is a `UInt32`. Deriving it
    // means a future sample-rate or bit-depth change moves the warning with it, rather than leaving
    // a constant that quietly describes the wrong format — which is the F208/F196 failure applied
    // to a number instead of a sentence.
    let bytesPerSecond = 48_000.0 * 2
    let expected = Double(UInt32.max) / bytesPerSecond
    #expect(abs(RecordingHealthMonitor.wavLengthLimitSeconds - expected) < 1)
    // ~12 h 25 m, as F150 states.
    #expect(RecordingHealthMonitor.wavLengthLimitSeconds > 44_000)
    #expect(RecordingHealthMonitor.wavLengthLimitSeconds < 45_000)
}

@Test("The warning reaches a snapshot, so the banner can show it (F150)")
func lengthWarningReachesTheSnapshot() {
    let monitor = RecordingHealthMonitor(startedAt: 0)
    let early = monitor.snapshot(at: 60, availableStorageBytes: 500_000_000_000)
    #expect(!early.warnings.contains(.approachingLengthLimit))

    let late = monitor.snapshot(
        at: RecordingHealthMonitor.wavLengthLimitSeconds - 60,
        availableStorageBytes: 500_000_000_000
    )
    #expect(late.warnings.contains(.approachingLengthLimit))
}
