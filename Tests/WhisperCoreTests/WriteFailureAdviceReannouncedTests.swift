import Foundation
import Testing
@testable import WhisperCore

// F960 — `RecordingRiskAnnouncer` announced `.captureWritesFailing` once per recording, worded from
// the snapshot of that moment. The HUD, banner and menu bar re-word it every second, but a user
// behind another app has only the notification: when one track's loss became both tracks' (F932),
// or a format failure became the disk's (F888), they kept "the rest is still recording" while the
// recording was losing everything — and the other way round, a "stop the recording" sent in the
// first second, before system audio had delivered, stood while the microphone alone was lost. The
// announcer now keys this warning on the sentence it says, so a change of advice is said once more,
// and each sentence is still said once in a recording (the anti-flapping rule).

private let quiet = RecordingAudioLevel(rms: 0.2, peak: 0.3)

/// Ten buffers a second. `microphone` / `systemAudio` give each track's outcome at a time: nil lands,
/// a cause fails, and `.none` from `systemAudioArrives` keeps a track from arriving at all.
private func drive(
    _ monitor: RecordingHealthMonitor,
    from start: Double, to end: Double,
    microphone: RecordingWriteFailureCause?,
    systemAudio: RecordingWriteFailureCause?,
    systemAudioArrives: Bool = true
) {
    var tick = Int(start * 10) + 1
    while Double(tick) / 10 <= end {
        let time = Double(tick) / 10
        if let microphone {
            monitor.recordWriteOutcome(.microphone, succeeded: false, cause: microphone)
        } else {
            monitor.recordWriteOutcome(.microphone, succeeded: true)
            monitor.receive(.microphone, level: quiet, at: time)
        }
        if systemAudioArrives {
            if let systemAudio {
                monitor.recordWriteOutcome(.systemAudio, succeeded: false, cause: systemAudio)
            } else {
                monitor.recordWriteOutcome(.systemAudio, succeeded: true)
                monitor.receive(.systemAudio, level: quiet, at: time)
            }
        }
        tick += 1
    }
}

@Test("When the other track fails too, the announcement is made again with the new advice; the same advice is not repeated (F960)")
func aSecondTrackFailingIsAnnouncedAgain() {
    var announcer = RecordingRiskAnnouncer()
    let monitor = RecordingHealthMonitor(startedAt: 0)

    drive(monitor, from: 0, to: 10, microphone: .format, systemAudio: nil)
    let oneTrack = monitor.snapshot(at: 10, availableStorageBytes: nil)
    #expect(oneTrack.unsavedTrack == .microphone)
    #expect(announcer.announcement(for: oneTrack)
            == "Recording needs attention: Microphone audio is not being saved — the rest is still recording.")
    #expect(announcer.announcement(for: monitor.snapshot(at: 10.1, availableStorageBytes: nil)) == nil,
            "the same advice, one second later")

    drive(monitor, from: 10.1, to: 20, microphone: .format, systemAudio: .format)
    let bothTracks = monitor.snapshot(at: 20, availableStorageBytes: nil)
    #expect(bothTracks.unsavedTrack == nil)
    #expect(announcer.announcement(for: bothTracks)
            == "Recording needs attention: Audio is not being saved — stop the recording.",
            "the user behind another app still has \"the rest is still recording\"")
    #expect(announcer.announcement(for: monitor.snapshot(at: 20.1, availableStorageBytes: nil)) == nil)
}

@Test("A \"stop\" sent before system audio had delivered is followed by the one-track advice once it has (F960)")
func theOneTrackAdviceFollowsAnEarlyStop() {
    var announcer = RecordingRiskAnnouncer()
    let monitor = RecordingHealthMonitor(startedAt: 0)

    // The microphone fails from its first buffer; the first at-risk tick comes about a second in,
    // before ScreenCaptureKit has delivered system audio, so nothing else is being saved yet.
    drive(monitor, from: 0, to: 1, microphone: .format, systemAudio: nil, systemAudioArrives: false)
    let early = monitor.snapshot(at: 1, availableStorageBytes: nil)
    #expect(early.warnings.contains(.captureWritesFailing))
    #expect(early.unsavedTrack == nil)
    #expect(announcer.announcement(for: early)
            == "Recording needs attention: Audio is not being saved — stop the recording.")

    drive(monitor, from: 1.1, to: 5, microphone: .format, systemAudio: nil)
    let later = monitor.snapshot(at: 5, availableStorageBytes: nil)
    #expect(later.unsavedTrack == .microphone)
    #expect(announcer.announcement(for: later)
            == "Recording needs attention: Microphone audio is not being saved — the rest is still recording.",
            "the notification on screen says to stop a recording that is still saving the others")
    #expect(announcer.announcement(for: monitor.snapshot(at: 5.1, availableStorageBytes: nil)) == nil)
}

@Test("Each sentence is said once in a recording: advice that flaps back is not repeated, and a change that keeps the sentence says nothing (F960)")
func eachSentenceIsSaidOnce() {
    // Format, one track, then both, then one again.
    var announcer = RecordingRiskAnnouncer()
    let monitor = RecordingHealthMonitor(startedAt: 0)
    drive(monitor, from: 0, to: 10, microphone: .format, systemAudio: nil)
    #expect(announcer.announcement(for: monitor.snapshot(at: 10, availableStorageBytes: nil)) != nil)
    drive(monitor, from: 10.1, to: 20, microphone: .format, systemAudio: .format)
    #expect(announcer.announcement(for: monitor.snapshot(at: 20, availableStorageBytes: nil)) != nil)
    drive(monitor, from: 20.1, to: 30, microphone: .format, systemAudio: nil)
    let back = monitor.snapshot(at: 30, availableStorageBytes: nil)
    #expect(back.unsavedTrack == .microphone, "sanity: one success reset the system track (F876)")
    #expect(announcer.announcement(for: back) == nil, "flapping between two sentences is bounded to one of each")

    // The disk: one track failing on it and then both say the same thing (F932 keeps "stop and check
    // disk space" for one track), so the second state is not an announcement.
    var diskAnnouncer = RecordingRiskAnnouncer()
    let disk = RecordingHealthMonitor(startedAt: 0)
    drive(disk, from: 0, to: 10, microphone: .storage, systemAudio: nil)
    #expect(diskAnnouncer.announcement(for: disk.snapshot(at: 10, availableStorageBytes: nil))
            == "Recording needs attention: Audio is not being saved — stop and check disk space.")
    drive(disk, from: 10.1, to: 20, microphone: .storage, systemAudio: .storage)
    #expect(diskAnnouncer.announcement(for: disk.snapshot(at: 20, availableStorageBytes: nil)) == nil,
            "the advice did not change, so there is nothing new to say")
}

@Test("A re-arm after a resume forgets the advice too (F960, F292)")
func rearmForgetsTheAdvice() {
    var announcer = RecordingRiskAnnouncer()
    let monitor = RecordingHealthMonitor(startedAt: 0)
    drive(monitor, from: 0, to: 10, microphone: .format, systemAudio: nil)
    let oneTrack = monitor.snapshot(at: 10, availableStorageBytes: nil)
    #expect(announcer.announcement(for: oneTrack) != nil)
    announcer.rearm()
    drive(monitor, from: 10.1, to: 20, microphone: nil, systemAudio: nil)
    let clean = monitor.snapshot(at: 20, availableStorageBytes: nil)
    #expect(clean.overallStatus != .atRisk)
    #expect(announcer.announcement(for: clean) == nil)
    drive(monitor, from: 20.1, to: 30, microphone: .format, systemAudio: nil)
    #expect(announcer.announcement(for: monitor.snapshot(at: 30, availableStorageBytes: nil)) != nil,
            "a new loss after a clean resume is announced, as any outage is")
}
