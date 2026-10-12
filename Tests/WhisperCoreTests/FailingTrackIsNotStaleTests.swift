import Foundation
import Testing
@testable import WhisperCore

// F931 — a track whose every append throws never reaches `RecordingHealthMonitor.receive`, so after
// the grace period it also read as stale. `.microphoneCaptureStopped` and `.captureWritesFailing`
// both rank 0, and the stale warning is listed first, so the HUD and the banner said "Microphone
// capture stopped", the panel said to check the microphone connection, and "not being saved" came
// only as a second announcement. Buffers were arriving the whole time; they were not being saved.
// Wave 5 lane Q2 measured this with a throwaway probe (`F888-green.txt`, lines `Q2PROBE`); this is
// that probe as a test.

private let quiet = RecordingAudioLevel(rms: 0.2, peak: 0.3)

/// The microphone fails every buffer on its format while system audio lands, ten buffers a second
/// for ten seconds: far past the 4 s grace and the 3 s staleness. `heardFirst` is the probe's
/// second case, a microphone that delivered once at 0.5 s and then failed.
private func microphoneFailingEveryBuffer(heardFirst: Bool) -> RecordingHealthMonitor {
    let monitor = RecordingHealthMonitor(startedAt: 0)
    if heardFirst { monitor.receive(.microphone, level: quiet, at: 0.5) }
    for tick in 6..<100 {
        let time = Double(tick) / 10
        monitor.recordWriteOutcome(.microphone, succeeded: false, cause: .format)
        monitor.recordWriteOutcome(.systemAudio, succeeded: true)
        monitor.receive(.systemAudio, level: quiet, at: time)
    }
    return monitor
}

@Test("A track that fails every buffer is reported as not being saved, not as stopped, on every surface (F931)",
      arguments: [false, true])
func aTrackFailingEveryBufferIsNotAlsoStale(heardFirst: Bool) {
    let monitor = microphoneFailingEveryBuffer(heardFirst: heardFirst)
    let snapshot = monitor.snapshot(at: 10, availableStorageBytes: nil)

    #expect(snapshot.warnings.contains(.captureWritesFailing), "sanity: \(snapshot.warnings)")
    #expect(!snapshot.warnings.contains(.microphoneCaptureStopped),
            "its buffers are arriving and are not being saved; nothing about it has stopped")
    // The in-window panel words `warnings.first` (`RecordMeetingView.statusReason`).
    #expect(snapshot.warnings.first == .captureWritesFailing, "the panel's line: \(snapshot.warnings)")
    let hud = RecordingHUD.make(isRecording: true, isStopping: false, elapsedSeconds: 10, health: snapshot, level: 0)
    let banner = MenuBarRecording.riskBannerLine(isRecording: true, isStopping: false, health: snapshot)
    var announcer = RecordingRiskAnnouncer()
    let first = announcer.announcement(for: snapshot)
    let second = announcer.announcement(for: snapshot)
    for (surface, line) in [("HUD", hud.topWarning), ("banner", banner), ("first announcement", first)] {
        #expect(line?.contains("not being saved") == true, "\(surface): \(line ?? "<nothing>")")
        #expect(line?.contains("stopped") == false, "\(surface): \(line ?? "<nothing>")")
    }
    #expect(second == nil, "no second announcement sending the user to check a connection that works")
    // And the saved report agrees, so the meeting page does not say the microphone stopped either.
    let advisory = RecordingHealthAdvisory.message(for: monitor.report()) ?? ""
    #expect(!advisory.contains("Microphone capture stopped"), "\(advisory)")
}

@Test("A microphone that stops arriving is still reported stopped, and so is one that recovered and then stopped (F931 control)")
func aTrackThatStopsArrivingIsStillStale() {
    // Heard once, then nothing at all: not a write failure, a microphone that went away.
    let silent = RecordingHealthMonitor(startedAt: 0)
    silent.receive(.microphone, level: quiet, at: 0.5)
    for tick in 6..<100 { silent.receive(.systemAudio, level: quiet, at: Double(tick) / 10) }
    #expect(silent.snapshot(at: 10, availableStorageBytes: nil).warnings.contains(.microphoneCaptureStopped))

    // Failing writes, then one success ends the run (F876's reset), then nothing arrives.
    let recovered = RecordingHealthMonitor(startedAt: 0)
    for _ in 0..<5 { recovered.recordWriteOutcome(.microphone, succeeded: false, cause: .format) }
    recovered.recordWriteOutcome(.microphone, succeeded: true)
    recovered.receive(.microphone, level: quiet, at: 1)
    for tick in 10..<100 { recovered.receive(.systemAudio, level: quiet, at: Double(tick) / 10) }
    let snapshot = recovered.snapshot(at: 10, availableStorageBytes: nil)
    #expect(!snapshot.warnings.contains(.captureWritesFailing))
    #expect(snapshot.warnings.contains(.microphoneCaptureStopped))
}

@Test("System audio failing every buffer is not reported stopped either (F931)")
func systemAudioFailingEveryBufferIsNotStale() {
    let monitor = RecordingHealthMonitor(startedAt: 0)
    monitor.receive(.systemAudio, level: quiet, at: 0.5)
    for tick in 6..<100 {
        let time = Double(tick) / 10
        monitor.recordWriteOutcome(.systemAudio, succeeded: false, cause: .format)
        monitor.recordWriteOutcome(.microphone, succeeded: true)
        monitor.receive(.microphone, level: quiet, at: time)
    }
    let snapshot = monitor.snapshot(at: 10, availableStorageBytes: nil)
    #expect(snapshot.warnings.contains(.captureWritesFailing))
    #expect(!snapshot.warnings.contains(.systemAudioCaptureStopped), "\(snapshot.warnings)")
}
