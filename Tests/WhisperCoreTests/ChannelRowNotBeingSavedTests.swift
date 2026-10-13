import Foundation
import Testing
@testable import WhisperCore

// F970 — the record screen's per-channel chip used to show red "No audio for 3s+" for a track whose
// buffers arrive and fail to save, because such a track also read as stale. F931 stopped reporting
// it stale (it is not), and the chip then fell through to the level meter, which is fed only by a
// buffer that reached the disk — so it decayed to grey "Silent" while the user was speaking into a
// microphone whose audio was being lost, against the row's own rule that capture warnings take
// precedence over activity. The rule now lives in `RecordingChannelRowState`, and the snapshot
// says which tracks' writes are failing (`tracksWithFailingWrites`), so the chip can name this
// track's loss without guessing from the one-track `unsavedTrack`.

private let quiet = RecordingAudioLevel(rms: 0.2, peak: 0.3)

/// `seconds` of buffers, ten a second. Each track lands (`nil`) or fails every buffer with the
/// given cause; `systemAudioNeverArrives` delivers no system buffer at all.
private func monitor(
    microphone: RecordingWriteFailureCause?,
    systemAudio: RecordingWriteFailureCause?,
    systemAudioNeverArrives: Bool = false,
    seconds: Int = 10
) -> RecordingHealthMonitor {
    let monitor = RecordingHealthMonitor(startedAt: 0)
    for tick in 1..<(seconds * 10) {
        let time = Double(tick) / 10
        if let microphone {
            monitor.recordWriteOutcome(.microphone, succeeded: false, cause: microphone)
        } else {
            monitor.recordWriteOutcome(.microphone, succeeded: true)
            monitor.receive(.microphone, level: quiet, at: time)
        }
        guard !systemAudioNeverArrives else { continue }
        if let systemAudio {
            monitor.recordWriteOutcome(.systemAudio, succeeded: false, cause: systemAudio)
        } else {
            monitor.recordWriteOutcome(.systemAudio, succeeded: true)
            monitor.receive(.systemAudio, level: quiet, at: time)
        }
    }
    return monitor
}

private func row(_ channel: RecordingChannel, _ health: RecordingHealthSnapshot, active: Bool = false) -> RecordingChannelRowState {
    RecordingChannelRowState.make(channel: channel, health: health, isActive: active)
}

@Test("A microphone whose buffers fail to save reads \"Not being saved\", in red, not \"Silent\" (F970)")
func aFailingMicrophoneIsNotSilent() {
    let health = monitor(microphone: .format, systemAudio: nil).snapshot(at: 10, availableStorageBytes: nil)
    #expect(health.warnings.contains(.captureWritesFailing))
    #expect(!health.warnings.contains(.microphoneCaptureStopped), "F931: its buffers are arriving")

    // The meter is fed only by a successful append, so it reads inactive while the user speaks.
    let microphone = row(.microphone, health, active: false)
    #expect(microphone.text == "Not being saved", "\(microphone)")
    #expect(microphone.tone == .lost)
    // The other track is still being saved and its chip says so from its own activity.
    #expect(row(.systemAudio, health, active: true).text == "Receiving audio")
    #expect(row(.systemAudio, health, active: false).text == "Silent (normal until others speak)")
}

@Test("System audio whose buffers fail to save from the first one reads \"Not being saved\", not \"Not detected yet\" (F970)")
func failingSystemAudioIsNotUndetected() {
    // Its buffers never reach `receive`, so the monitor also lists it as not detected; the loss
    // outranks that caution on its own row as it does on every other surface.
    let health = monitor(microphone: nil, systemAudio: .format, seconds: 16).snapshot(at: 16, availableStorageBytes: nil)
    #expect(health.warnings.contains(.captureWritesFailing))
    let system = row(.systemAudio, health)
    #expect(system.text == "Not being saved", "\(system)")
    #expect(system.tone == .lost)
    #expect(row(.microphone, health, active: true).text == "Receiving audio")
}

@Test("Both tracks failing marks both rows; a disk failure marks them the same way (F970)")
func bothFailingMarksBothRows() {
    for cause in [RecordingWriteFailureCause.format, .storage] {
        let health = monitor(microphone: cause, systemAudio: cause).snapshot(at: 10, availableStorageBytes: nil)
        #expect(health.unsavedTrack == nil, "sanity: F932 names no track when both are lost")
        #expect(row(.microphone, health, active: true).text == "Not being saved", "\(cause)")
        #expect(row(.systemAudio, health, active: true).text == "Not being saved", "\(cause)")
    }
}

@Test("The other track's own state is kept: never arrived stays \"Not detected yet\", stopped stays \"No audio for 3s+\" (F970)")
func theOtherTracksOwnStateIsKept() {
    // Microphone failing, system audio never delivered: `unsavedTrack` is nil (nothing else is being
    // saved), and the system row must not borrow the microphone's loss.
    let neverArrived = monitor(microphone: .format, systemAudio: nil, systemAudioNeverArrives: true, seconds: 16)
        .snapshot(at: 16, availableStorageBytes: nil)
    #expect(neverArrived.unsavedTrack == nil)
    #expect(row(.microphone, neverArrived).text == "Not being saved")
    #expect(row(.systemAudio, neverArrived) == RecordingChannelRowState(text: "Not detected yet", tone: .caution))

    // Microphone failing, system audio delivered and then stopped.
    let stopped = RecordingHealthMonitor(startedAt: 0)
    for tick in 1..<100 {
        let time = Double(tick) / 10
        stopped.recordWriteOutcome(.microphone, succeeded: false, cause: .format)
        if time <= 5 {
            stopped.recordWriteOutcome(.systemAudio, succeeded: true)
            stopped.receive(.systemAudio, level: quiet, at: time)
        }
    }
    let stoppedHealth = stopped.snapshot(at: 10, availableStorageBytes: nil)
    #expect(stoppedHealth.warnings.contains(.systemAudioCaptureStopped))
    #expect(row(.systemAudio, stoppedHealth) == RecordingChannelRowState(text: "No audio for 3s+", tone: .lost))
    #expect(row(.microphone, stoppedHealth).text == "Not being saved")
}

@Test("The chip's other states are unchanged by the move into WhisperCore (F970 control)")
func theOtherStatesAreUnchanged() {
    let healthy = monitor(microphone: nil, systemAudio: nil).snapshot(at: 10, availableStorageBytes: nil)
    #expect(healthy.warnings.isEmpty)
    #expect(row(.microphone, healthy, active: true) == RecordingChannelRowState(text: "Receiving audio", tone: .receiving))
    #expect(row(.microphone, healthy, active: false) == RecordingChannelRowState(text: "Silent", tone: .quiet))
    #expect(row(.systemAudio, healthy, active: true) == RecordingChannelRowState(text: "Receiving audio", tone: .receiving))
    #expect(row(.systemAudio, healthy, active: false)
            == RecordingChannelRowState(text: "Silent (normal until others speak)", tone: .quiet))

    let clipping = RecordingHealthSnapshot(
        microphoneLevel: quiet, systemAudioLevel: quiet, availableStorageBytes: nil,
        warnings: [.microphoneClipping, .systemAudioClipping]
    )
    #expect(row(.microphone, clipping, active: true) == RecordingChannelRowState(text: "Too loud", tone: .caution))
    #expect(row(.systemAudio, clipping, active: true) == RecordingChannelRowState(text: "Too loud", tone: .caution))

    let stopped = RecordingHealthSnapshot(
        microphoneLevel: .silent, systemAudioLevel: .silent, availableStorageBytes: nil,
        warnings: [.microphoneCaptureStopped, .systemAudioCaptureStopped]
    )
    #expect(row(.microphone, stopped) == RecordingChannelRowState(text: "No audio for 3s+", tone: .lost))
    #expect(row(.systemAudio, stopped) == RecordingChannelRowState(text: "No audio for 3s+", tone: .lost))
}
