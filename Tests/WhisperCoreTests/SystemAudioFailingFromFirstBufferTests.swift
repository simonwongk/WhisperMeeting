import Foundation
import Testing
@testable import WhisperCore

// F982 — `RecordingHealthMonitor.receive` runs only after a successful append, so a system track whose
// every buffer arrives and fails to save never reached it. The monitor then also called that track
// "not detected": `.systemAudioNotDetected` joined `.captureWritesFailing` in the warnings, and the
// saved report's `systemAudioEverDetected` was false, which `RecordingHealthAdvisory` words as "No
// system (meeting) audio was detected during this recording." The audio was there; the app failed
// to save it.
//
// A failed write counts as arrival for detection only. It is not a delivery for staleness, because
// a failing track is not a track that is still being saved (F931 keeps the two apart).

private let quiet = RecordingAudioLevel(rms: 0.2, peak: 0.3)

/// The system track fails every buffer from its first while the microphone lands, ten buffers a
/// second for `seconds`, past the 15 s detection grace.
private func systemAudioFailingFromItsFirstBuffer(seconds: Int = 20) -> RecordingHealthMonitor {
    let monitor = RecordingHealthMonitor(startedAt: 0)
    for tick in 1..<(seconds * 10) {
        let time = Double(tick) / 10
        monitor.recordWriteOutcome(.systemAudio, succeeded: false, cause: .storage)
        monitor.recordWriteOutcome(.microphone, succeeded: true)
        monitor.receive(.microphone, level: quiet, at: time)
    }
    return monitor
}

@Test("A system track whose buffers arrive and fail to save is not reported as never detected (F982)")
func failingSystemAudioIsStillDetected() {
    let monitor = systemAudioFailingFromItsFirstBuffer()
    let snapshot = monitor.snapshot(at: 20, availableStorageBytes: nil)

    #expect(snapshot.warnings.contains(.captureWritesFailing), "sanity: \(snapshot.warnings)")
    #expect(!snapshot.warnings.contains(.systemAudioNotDetected),
            "its buffers arrived; they were not saved: \(snapshot.warnings)")

    let report = monitor.report()
    #expect(report.systemAudioEverDetected, "the saved report blames the source for audio the app failed to save")
    let advisory = RecordingHealthAdvisory.message(for: report) ?? ""
    #expect(!advisory.contains("No system (meeting) audio was detected"), "\(advisory)")
}

@Test("A failed system write is arrival for detection only, never a delivery for staleness (F982)")
func aFailedWriteIsNotADelivery() {
    let monitor = systemAudioFailingFromItsFirstBuffer()
    _ = monitor.snapshot(at: 10, availableStorageBytes: nil)
    _ = monitor.snapshot(at: 20, availableStorageBytes: nil)
    // Nothing of system audio was ever saved, so it never delivered, never went stale, and is not
    // the track still being saved. The live surfaces keep saying "not being saved" (F959, F970).
    let snapshot = monitor.snapshot(at: 21, availableStorageBytes: nil)
    #expect(!snapshot.warnings.contains(.systemAudioCaptureStopped), "\(snapshot.warnings)")
    #expect(snapshot.unsavedTrack == .systemAudio, "the microphone is still being saved")
    #expect(monitor.report().systemAudioStaleSeconds == 0)
}

@Test("System audio that never arrives at all is still reported as not detected (F982 control)")
func systemAudioThatNeverArrivesIsStillNotDetected() {
    let monitor = RecordingHealthMonitor(startedAt: 0)
    for tick in 1..<200 {
        monitor.recordWriteOutcome(.microphone, succeeded: true)
        monitor.receive(.microphone, level: quiet, at: Double(tick) / 10)
    }
    let snapshot = monitor.snapshot(at: 20, availableStorageBytes: nil)
    #expect(snapshot.warnings.contains(.systemAudioNotDetected), "\(snapshot.warnings)")
    #expect(!monitor.report().systemAudioEverDetected)
}
