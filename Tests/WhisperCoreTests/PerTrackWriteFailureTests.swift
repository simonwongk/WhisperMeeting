import Foundation
import Testing
@testable import WhisperCore

// F876 — the at-risk "Audio is not being saved" warning never fired for ONE track failing.
//
// F386's count of consecutive failed writes was one number for both tracks, and the sample handler
// reports both tracks into it. So while the other track kept landing, each of its successes reset
// the failing track's count, and the threshold was never reached. The review drove the real monitor
// with 400 alternating fail/success pairs: `writesAreFailing=false warnings=[microphoneCaptureStopped]`.
// What the user saw instead was the wrong sentence:
// - a dead microphone track: "Microphone audio stopped arriving. Check the microphone connection."
//   (staleness), which is the wrong advice for a write or format failure (F856, F875);
// - a system track dead from its first buffer: only the non-at-risk "No system audio has been detected
//   yet".
// The count is now kept per track, and either track reaching the threshold raises the warning.

private let quiet = RecordingAudioLevel(rms: 0.2, peak: 0.3)

@discardableResult
private func tick(_ monitor: RecordingHealthMonitor, at time: TimeInterval) -> RecordingHealthSnapshot {
    monitor.snapshot(at: time, availableStorageBytes: nil)
}

private func receivingMonitor() -> RecordingHealthMonitor {
    let monitor = RecordingHealthMonitor(startedAt: 0)
    monitor.receive(.systemAudio, level: quiet, at: 1)
    monitor.receive(.microphone, level: quiet, at: 1)
    return monitor
}

@Test("The microphone failing every buffer while system audio lands raises the at-risk warning (F876)")
func microphoneFailingBesideALandingSystemTrackIsSurfaced() {
    let monitor = receivingMonitor()
    for _ in 0..<400 {
        monitor.recordWriteOutcome(.microphone, succeeded: false)
        monitor.recordWriteOutcome(.systemAudio, succeeded: true)
    }
    #expect(monitor.writesAreFailing)
    let snapshot = tick(monitor, at: 2)
    #expect(snapshot.warnings.contains(.captureWritesFailing), "\(snapshot.warnings)")
    #expect(snapshot.overallStatus == .atRisk)
    #expect(monitor.report().worstStatus == .atRisk)
}

@Test("System audio failing from its first buffer while the microphone lands raises it too (F876)")
func systemFailingFromTheStartIsSurfaced() {
    let monitor = RecordingHealthMonitor(startedAt: 0)
    monitor.receive(.microphone, level: quiet, at: 1)
    for _ in 0..<3 {
        monitor.recordWriteOutcome(.systemAudio, succeeded: false)
        monitor.recordWriteOutcome(.microphone, succeeded: true)
        monitor.recordWriteOutcome(.microphone, succeeded: true)
    }
    let snapshot = tick(monitor, at: 2)
    #expect(snapshot.warnings.contains(.captureWritesFailing), "\(snapshot.warnings)")
}

@Test("Each track's count resets only on its own success, and the warning clears when it recovers (F876)")
func eachTrackResetsOnlyItsOwnCount() {
    let monitor = receivingMonitor()
    // Interleavings: two microphone failures either side of a system success are still consecutive
    // for the microphone.
    monitor.recordWriteOutcome(.microphone, succeeded: false)
    monitor.recordWriteOutcome(.microphone, succeeded: false)
    monitor.recordWriteOutcome(.systemAudio, succeeded: true)
    #expect(!monitor.writesAreFailing, "two failures is a blip, as F386 decided")
    monitor.recordWriteOutcome(.microphone, succeeded: false)
    #expect(monitor.writesAreFailing)
    // A system success does not clear it; a microphone success does, so the live banner recovers.
    monitor.recordWriteOutcome(.systemAudio, succeeded: true)
    #expect(monitor.writesAreFailing)
    monitor.recordWriteOutcome(.microphone, succeeded: true)
    #expect(!monitor.writesAreFailing)
    #expect(!tick(monitor, at: 2).warnings.contains(.captureWritesFailing))
}

@Test("Blips on both tracks never add up to the warning (F876 control)")
func blipsOnBothTracksAreNotAnAlarm() {
    // F386's safety property, per track: a failure on one track cannot add to the other's count.
    let monitor = receivingMonitor()
    for _ in 0..<200 {
        monitor.recordWriteOutcome(.microphone, succeeded: false)
        monitor.recordWriteOutcome(.systemAudio, succeeded: false)
        monitor.recordWriteOutcome(.microphone, succeeded: false)
        monitor.recordWriteOutcome(.systemAudio, succeeded: false)
        monitor.recordWriteOutcome(.microphone, succeeded: true)
        monitor.recordWriteOutcome(.systemAudio, succeeded: true)
    }
    #expect(!monitor.writesAreFailing)
    #expect(!tick(monitor, at: 2).warnings.contains(.captureWritesFailing))
}

@Test("Both tracks failing raise the warning once, not once per track (F876)")
func bothTracksFailingRaiseOneWarning() {
    let monitor = receivingMonitor()
    for _ in 0..<5 {
        monitor.recordWriteOutcome(.microphone, succeeded: false)
        monitor.recordWriteOutcome(.systemAudio, succeeded: false)
    }
    let warnings = tick(monitor, at: 2).warnings
    #expect(warnings.filter { $0 == .captureWritesFailing }.count == 1, "\(warnings)")
}
