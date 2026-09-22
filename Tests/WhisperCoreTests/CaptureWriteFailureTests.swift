import Foundation
import Testing
@testable import WhisperCore

// F386 — the meeting-capture half of F368, and the worst failure this app can have.
//
// Since F363 stopped a failed buffer write tearing the stream down, a *persistent* write failure
// drops every buffer while the recording appears to continue: the HUD counts up, the level meter
// moves, and nothing reaches disk. The user records for an hour and has nothing. It was not
// surfaced before F363 either — the bogus restart was the only signal, and it was lying — so this
// is an unclosed hole rather than a regression.
//
// `_streamError` records the failure and surfaces nowhere. What makes it visible is an at-risk
// warning, which `RecordingRiskAnnouncer` and the menu-bar title already carry.

private let quiet = RecordingAudioLevel(rms: 0.2, peak: 0.3)

/// A health tick, which is what folds live warnings into the running report.
///
/// `report()` returns `seenWarnings`, accumulated by `snapshot(at:)` — so a test that calls
/// `report()` without ticking is asking what the capture has seen, having shown it nothing. The
/// health timer ticks in production; these do the same rather than reaching past it.
@discardableResult
private func tick(_ monitor: RecordingHealthMonitor, at time: TimeInterval) -> RecordingHealthSnapshot {
    monitor.snapshot(at: time, availableStorageBytes: nil)
}

@Test("Three consecutive failed writes raise an at-risk warning (F386)")
func persistentWriteFailureIsSurfaced() {
    let monitor = RecordingHealthMonitor(startedAt: 0)
    monitor.receive(.systemAudio, level: quiet, at: 1)
    monitor.receive(.microphone, level: quiet, at: 1)

    for _ in 0..<2 { monitor.recordWriteOutcome(succeeded: false) }
    #expect(!tick(monitor, at: 2).warnings.contains(.captureWritesFailing),
            "two failures is a blip, and a warning on every blip is a warning nobody reads")

    monitor.recordWriteOutcome(succeeded: false)
    #expect(tick(monitor, at: 3).warnings.contains(.captureWritesFailing),
            "the live snapshot is what the HUD and the menu bar read")
    let report = monitor.report()
    #expect(report.warnings.contains(.captureWritesFailing))
    #expect(report.worstStatus == .atRisk, "audio is being lost right now: \(report.worstStatus)")
    #expect(RecordingHealthWarning.captureWritesFailing.isAtRisk)
}

@Test("A single success resets the count, so a blip cannot accumulate into an alarm (F386)")
func oneSuccessResetsTheCount() {
    // The property that makes a threshold of three safe. A cumulative count would creep past any
    // threshold over a long recording and raise an alarm about a capture that is working.
    let monitor = RecordingHealthMonitor(startedAt: 0)
    monitor.receive(.systemAudio, level: quiet, at: 1)
    monitor.receive(.microphone, level: quiet, at: 1)
    for _ in 0..<200 {
        monitor.recordWriteOutcome(succeeded: false)
        monitor.recordWriteOutcome(succeeded: false)
        monitor.recordWriteOutcome(succeeded: true)
    }
    #expect(!monitor.writesAreFailing)
    #expect(!tick(monitor, at: 2).warnings.contains(.captureWritesFailing))

    // And the LIVE warning recovers: writes that start working clear it rather than latching, so a
    // volume that comes back does not leave a red banner on a healthy recording.
    for _ in 0..<5 { monitor.recordWriteOutcome(succeeded: false) }
    #expect(tick(monitor, at: 3).warnings.contains(.captureWritesFailing))
    monitor.recordWriteOutcome(succeeded: true)
    #expect(!tick(monitor, at: 4).warnings.contains(.captureWritesFailing))

    // The completed-meeting REPORT keeps it, and that difference is deliberate: the banner is
    // about now, and the saved report is about what happened. A recording that lost five buffers
    // and recovered still lost them.
    #expect(monitor.report().warnings.contains(.captureWritesFailing))
}

@Test("The warning outranks every other and says what to do (F386)")
func theWarningIsRankedAndWorded() {
    // Ranked with a dead channel, and arguably worse: a stopped channel still leaves the other
    // one, and this leaves nothing.
    #expect(RecordingHUD.rank(.captureWritesFailing) == RecordingHUD.rank(.microphoneCaptureStopped))
    #expect(RecordingHUD.rank(.captureWritesFailing) < RecordingHUD.rank(.lowStorage))
    let top = RecordingHUD.topWarning(from: [.systemAudioClipping, .captureWritesFailing, .lowStorage])
    #expect(top == "Audio is not being saved — stop and check disk space", "\(top ?? "")")

    // The completed-meeting advisory says what was lost, not what failed.
    let report = RecordingHealthReport(
        warnings: [.captureWritesFailing], worstStatus: .atRisk,
        microphoneStaleSeconds: 0, systemAudioStaleSeconds: 0, systemAudioEverDetected: true
    )
    let message = RecordingHealthAdvisory.message(for: report) ?? ""
    #expect(message.contains("was not saved"), "\(message)")
    #expect(message.contains("intact"), "it must also say what survived: \(message)")
}

@Test("The warning survives a save and reload (F386)")
func theWarningRoundTrips() throws {
    let report = RecordingHealthReport(
        warnings: [.captureWritesFailing], worstStatus: .atRisk,
        microphoneStaleSeconds: 0, systemAudioStaleSeconds: 0, systemAudioEverDetected: true
    )
    let data = try JSONEncoder().encode(report)
    #expect(try #require(String(data: data, encoding: .utf8)).contains("captureWritesFailing"))
    let decoded = try JSONDecoder().decode(RecordingHealthReport.self, from: data)
    #expect(decoded.warnings == [.captureWritesFailing])

    // And an older build, which drops warnings it cannot name (F188's lenient decode), still
    // reads the rest of the report rather than failing the whole meetings array.
    let unknown = Data("""
        {"warnings":["captureWritesFailing","somethingNewer"],"worstStatus":"atRisk",
         "microphoneStaleSeconds":0,"systemAudioStaleSeconds":0,"systemAudioEverDetected":true}
        """.utf8)
    let lenient = try JSONDecoder().decode(RecordingHealthReport.self, from: unknown)
    #expect(lenient.warnings == [.captureWritesFailing])
}

@Test("A capture with no write trouble says nothing new (F386)")
func aHealthyCaptureIsUnchanged() {
    // The control. A warning that appears on a working recording is worse than none, and the
    // monitor is asked for a report on every tick of every capture.
    let monitor = RecordingHealthMonitor(startedAt: 0)
    monitor.receive(.systemAudio, level: quiet, at: 1)
    monitor.receive(.microphone, level: quiet, at: 1)
    for _ in 0..<500 { monitor.recordWriteOutcome(succeeded: true) }
    tick(monitor, at: 2)
    let report = monitor.report()
    #expect(!report.warnings.contains(.captureWritesFailing))
    #expect(report.worstStatus == .good, "\(report.worstStatus) \(report.warnings)")
}
