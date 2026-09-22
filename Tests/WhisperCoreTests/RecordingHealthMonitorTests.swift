import Foundation
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

// MARK: - F302: the WAV length limit no longer warns, because RF64 removed it

@Test("A very long recording is no longer warned about: RF64 keeps it readable (F302, was F150)")
func lengthWarningIsRetired() {
    let monitor = RecordingHealthMonitor(startedAt: 0)
    // Well past where the classic WAV `data` field runs out — 48 kHz mono 16-bit is 96,000 bytes a
    // second against a `UInt32`, so ~44,739 s (12 h 25 m). The derivation used to live in a constant
    // on the monitor; with nothing warning, the constant was two green tests of an unreachable
    // helper, so it is written out here instead (F335).
    let pastTheClassicWAVLimit = Double(UInt32.max) / (48_000.0 * 2) + 3_600
    let late = monitor.snapshot(at: pastTheClassicWAVLimit, availableStorageBytes: 500_000_000_000)
    #expect(!late.warnings.contains(.approachingLengthLimit))
}

// MARK: - F346: one spike and sustained clipping must not read the same

// The shipped rule marks a channel clipped after ANY buffer whose peak reaches 0.98, and the report
// persists only a Set of warning names. So a recording with 139 full-scale samples out of 14.4
// million and one that is flat-topped for 14% of its length produce byte-identical reports and the
// identical permanent sentence, "System audio was clipping (too loud) at times."
//
// That is not merely imprecise: it sent a real investigation the wrong way. Three recordings
// carried the flag; replaying two of them found 139 and 19 samples at the rail, which is 0.001% and
// 0.0001% — not a level fault at all, while the actual defect was in the mixer (F345).
//
// The fix records the evidence and stops asserting the verdict: a count of N frames at full scale
// out of M measured cannot be wrong, only its interpretation can.

@Test("A handful of full-scale frames and sustained clipping produce different reports (F346)")
func oneFullScaleBufferAndSustainedClippingDoNotProduceTheSameReport() {
    func reportFor(framesAtFullScale: Int, of measured: Int) -> RecordingHealthReport {
        let monitor = RecordingHealthMonitor(startedAt: 100)
        monitor.receive(
            .systemAudio,
            level: .init(rms: 0.6, peak: 1, framesMeasured: measured, framesAtFullScale: framesAtFullScale),
            at: 101
        )
        _ = monitor.snapshot(at: 102, availableStorageBytes: 20_000_000_000)
        return monitor.report()
    }

    let spikes = reportFor(framesAtFullScale: 139, of: 14_400_000)
    let sustained = reportFor(framesAtFullScale: 2_029_200, of: 14_400_000)

    // Both still raise the warning — the trigger is deliberately unchanged, so a recording that
    // used to be flagged still is.
    #expect(spikes.warnings.contains(.systemAudioClipping))
    #expect(sustained.warnings.contains(.systemAudioClipping))

    // And they are now distinguishable, which is the whole ticket.
    #expect(spikes.systemAudioFramesAtFullScale == 139)
    #expect(sustained.systemAudioFramesAtFullScale == 2_029_200)
    #expect(spikes.systemAudioFramesMeasured == 14_400_000)
    #expect(spikes != sustained, "one spike and a flat-topped recording still read the same")
}

// MARK: - F346: the words, the wire, and the floor

@Test("The clipping note reports what was measured, in every band (F346)")
func clippingNoteReportsTheMeasurement() {
    func note(_ atFullScale: Int?, of measured: Int?) -> String {
        RecordingHealthAdvisory.clippingNote(
            subject: "System audio", measured: measured, atFullScale: atFullScale,
            sustainedTail: " The source may already have been at its limit before it reached this Mac."
        )
    }
    // Every report written before F346. It must NOT keep the old sentence — that sentence is the
    // defect — but it must also not invent a figure it does not have.
    #expect(note(nil, of: nil).contains("predates the measurement"))
    #expect(!note(nil, of: nil).contains("(too loud)"))

    // Measured, and nothing was at the rail: the loud-but-clean case, which is the common one.
    #expect(note(0, of: 14_400_000).contains("not one of its 14,400,000 samples reached it"))

    // F346's own two tracks — 139 and 19 samples. The band that sent the last investigation wrong.
    #expect(note(139, of: 14_400_000).contains("about 1 in 103,597"))
    #expect(note(139, of: 14_400_000).contains("far too few to be a level problem"))

    // The mildest audible clipping that could be synthesised, at 0.18%.
    #expect(note(25_800, of: 14_400_000).contains("(0.18%)"))
    #expect(note(25_800, of: 14_400_000).contains("may be distorted"))

    // Flat-topped for a seventh of its length. Only here does it assert distortion outright.
    #expect(note(2_029_200, of: 14_400_000).contains("(14%)"))
    #expect(note(2_029_200, of: 14_400_000).contains("will sound distorted"))

    // Incoherent input degrades to the unmeasured sentence rather than dividing by zero.
    #expect(note(5, of: 0).contains("predates the measurement"))
    #expect(note(99, of: 10).contains("predates the measurement"))
}

@Test("The full-scale floor counts only frames at the rail (F346)")
func theFloorCountsOnlyFramesAtTheRail() {
    let floor = RecordingHealthMonitor.fullScaleFloor
    #expect(floor == 0.999969482421875, "32767/32768 exactly — a dyadic rational, held without rounding")
    let probes: [Float] = [0.97, 0.98, 0.9999, 0.999969482421875, 1.0, 1.4, -1.0, -0.999969482421875, -0.98]
    #expect(probes.filter { abs($0) >= floor }.count == 5)
    // 0.98 raises the WARNING and is nowhere near the rail. Keeping the two numbers apart is the
    // point: one asks "worth mentioning", the other asks "did this actually clip".
    #expect(Float(0.98) < floor)
}

@Test("A report written before the count still decodes, and a poisoned count does not spread (F346)")
func olderAndPoisonedReportsStillDecode() throws {
    let before = """
    {"warnings":["lowStorage"],"worstStatus":"caution","microphoneStaleSeconds":0,
     "systemAudioStaleSeconds":0,"systemAudioEverDetected":true}
    """
    let old = try JSONDecoder().decode(RecordingHealthReport.self, from: Data(before.utf8))
    #expect(old.warnings == [.lowStorage])
    #expect(old.systemAudioFramesMeasured == nil, "absent is not zero — zero would claim a measurement")

    // A float where an Int belongs must degrade THIS FIELD, not fail the report — the same
    // leniency the warnings decode exists for, since one bad report would take the whole
    // meetings.json array with it.
    let poisoned = """
    {"warnings":[],"worstStatus":"good","microphoneStaleSeconds":0,"systemAudioStaleSeconds":0,
     "systemAudioEverDetected":true,"systemAudioFramesAtFullScale":1e20}
    """
    let survived = try JSONDecoder().decode(RecordingHealthReport.self, from: Data(poisoned.utf8))
    #expect(survived.systemAudioFramesAtFullScale == nil)
    #expect(survived.worstStatus == .good)
}

@Test("The counts reach the wire, asserted on the bytes rather than a round-trip (F346)")
func theCountsReachTheWire() throws {
    // A round-trip cannot see this failure: the fields are decoded by a hand-written initialiser,
    // so a forgotten ENCODE would still read back correctly from the value in memory. The Mirror
    // guard in MeetingRecordWireFormatTests walks MeetingRecord's own stored properties and does
    // not descend into this nested type, so nothing else covers it either.
    let report = RecordingHealthReport(
        warnings: [.systemAudioClipping], worstStatus: .caution,
        microphoneStaleSeconds: 0, systemAudioStaleSeconds: 0, systemAudioEverDetected: true,
        microphoneFramesMeasured: 14_400_000, microphoneFramesAtFullScale: 0,
        systemAudioFramesMeasured: 14_400_000, systemAudioFramesAtFullScale: 139
    )
    let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any]
    #expect(wire?["systemAudioFramesAtFullScale"] as? Int == 139)
    #expect(wire?["systemAudioFramesMeasured"] as? Int == 14_400_000)
    #expect(wire?["microphoneFramesAtFullScale"] as? Int == 0)
    #expect(wire?["microphoneFramesMeasured"] as? Int == 14_400_000)
}

@Test("A report carrying counts reads them back, which the wire assertion cannot see (F346)")
func aReportWithCountsDecodesBackToTheSameNumbers() throws {
    // The other direction, and it needs its own test. `theCountsReachTheWire` asserts the encoded
    // bytes and so catches a forgotten ENCODE; it passes untouched when the DECODE is missing,
    // because encoding reads the property in memory. Measured: declaring these `var` and deleting
    // their `decodeIfPresent` lines leaves that test, the old-report test and the monitor test all
    // green while every count silently becomes nil on reload.
    //
    // `let` with no default is what makes that mistake a build error rather than a silent one — but
    // only on a full compile, since definite initialisation runs in SIL and `swiftc -typecheck`
    // does not see it. So the property declaration and this test are two independent guards on the
    // same failure, and neither subsumes the other.
    let report = RecordingHealthReport(
        warnings: [.systemAudioClipping], worstStatus: .caution,
        microphoneStaleSeconds: 1.5, systemAudioStaleSeconds: 0, systemAudioEverDetected: true,
        microphoneFramesMeasured: 14_400_000, microphoneFramesAtFullScale: 0,
        systemAudioFramesMeasured: 14_400_000, systemAudioFramesAtFullScale: 139
    )
    let restored = try JSONDecoder().decode(
        RecordingHealthReport.self, from: JSONEncoder().encode(report)
    )
    // Individually, not with `==`: a single equality would report "not equal" without saying which
    // of the four went missing, and three of them can be nil while one survives.
    #expect(restored.microphoneFramesMeasured == 14_400_000)
    #expect(restored.microphoneFramesAtFullScale == 0)
    #expect(restored.systemAudioFramesMeasured == 14_400_000)
    #expect(restored.systemAudioFramesAtFullScale == 139)
}
