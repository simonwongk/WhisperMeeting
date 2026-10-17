import Foundation
import Testing
@testable import WhisperCore

// F984 — `RecordingHUD.rank` ties `.captureWritesFailing` with the two stopped-capture warnings, and
// `leadingWarning(in:)` broke the tie by array order. The monitor appends the stopped warnings first.
// So when the microphone failed every buffer and system audio delivered and then stopped, the panel,
// the HUD and the menu bar led with "System audio capture stopped" while nothing at all was being
// saved, and "stop the recording" reached only the notification, one tick later. The window's banner
// and the announcer each had a `min(by:)` of their own; both now ask `leadingWarning`. Reproduced in
// the Wave 7 lane U review; this is that reproduction as a test.
//
// Since F931 a stopped warning is never raised for a track whose own writes are failing, so a stopped
// warning beside `.captureWritesFailing` always names the OTHER track: one track is not being saved
// and the other has stopped. Nothing is being saved, and the write failure leads.

private let quiet = RecordingAudioLevel(rms: 0.2, peak: 0.3)

/// `failing` fails every buffer from the start; the other track delivers for five seconds and stops.
private func oneTrackFailingAndTheOtherStopped(
    failing: RecordingChannel,
    cause: RecordingWriteFailureCause
) -> RecordingHealthSnapshot {
    let delivering: RecordingChannel = failing == .microphone ? .systemAudio : .microphone
    let monitor = RecordingHealthMonitor(startedAt: 0)
    for tick in 1..<50 {
        monitor.recordWriteOutcome(failing, succeeded: false, cause: cause)
        monitor.recordWriteOutcome(delivering, succeeded: true)
        monitor.receive(delivering, level: quiet, at: Double(tick) / 10)
    }
    // The failing track keeps arriving and failing after the other stops.
    for _ in 50..<100 { monitor.recordWriteOutcome(failing, succeeded: false, cause: cause) }
    return monitor.snapshot(at: 10, availableStorageBytes: nil)
}

@Test("With one track not being saved and the other stopped, every live surface leads with the write failure (F984)",
      arguments: [RecordingChannel.microphone, .systemAudio], [RecordingWriteFailureCause.storage, .format])
func nothingSavedLeadsWithTheWriteFailure(failing: RecordingChannel, cause: RecordingWriteFailureCause) {
    let snapshot = oneTrackFailingAndTheOtherStopped(failing: failing, cause: cause)
    let stopped: RecordingHealthWarning = failing == .microphone ? .systemAudioCaptureStopped : .microphoneCaptureStopped

    // The fixture is the review's: both rank-0 warnings, the stopped one appended first, and no
    // track still being saved.
    #expect(snapshot.warnings.contains(stopped) && snapshot.warnings.contains(.captureWritesFailing),
            "sanity: \(snapshot.warnings)")
    #expect(snapshot.warnings.firstIndex(of: stopped)! < snapshot.warnings.firstIndex(of: .captureWritesFailing)!)
    #expect(snapshot.unsavedTrack == nil, "a stopped track beside a failing one leaves nothing being saved")

    #expect(RecordingHUD.leadingWarning(in: snapshot.warnings) == .captureWritesFailing)
    let hud = RecordingHUD.make(isRecording: true, isStopping: false, elapsedSeconds: 10, health: snapshot, level: 0)
    let banner = MenuBarRecording.riskBannerLine(isRecording: true, isStopping: false, health: snapshot)
    let menuBar = MenuBarRecording.make(
        isRecording: true, isStopping: false, elapsedSeconds: 10, canStartRecording: false,
        hasActiveTranscription: false, health: snapshot
    ).healthLine
    var announcer = RecordingRiskAnnouncer()
    let announcement = announcer.announcement(for: snapshot)
    for (surface, line) in [("HUD", hud.topWarning), ("banner", banner), ("menu bar", menuBar),
                            ("first announcement", announcement)] {
        #expect(line?.contains("not being saved — stop") == true, "\(surface): \(line ?? "<nothing>")")
    }
}

@Test("A tie between the two stopped warnings still leads with the first appended (F984 control)")
func aTieOfTwoStoppedWarningsKeepsTheFirst() {
    #expect(RecordingHUD.leadingWarning(in: [.microphoneCaptureStopped, .systemAudioCaptureStopped]) == .microphoneCaptureStopped)
    #expect(RecordingHUD.leadingWarning(in: [.systemAudioCaptureStopped, .microphoneCaptureStopped]) == .systemAudioCaptureStopped)
    // The write failure outranks neither low storage nor anything else it did not tie with before.
    #expect(RecordingHUD.leadingWarning(in: [.lowStorage, .captureWritesFailing]) == .captureWritesFailing)
    #expect(RecordingHUD.leadingWarning(in: [.systemAudioNotDetected, .lowStorage]) == .lowStorage)
}
