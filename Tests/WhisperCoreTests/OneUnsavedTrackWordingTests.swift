import Foundation
import Testing
@testable import WhisperCore

// F932 — F888 named the failure when one track's captured audio cannot be read (in practice a
// multi-input microphone, F856/F857), but kept F386's instruction to stop. The other track may still
// be recording, and stopping also ends the remote participants' audio. The user's decision
// (2026-10-12, the Wave 5 letter's question C): name the track and drop "stop", e.g. "Microphone
// audio is not being saved — the rest is still recording"; keep F386's "stop" advice for a full
// disk, where nothing is being saved.
//
// Every live surface that words the warning is read from one snapshot, as F888's tests do: the
// window's banner, the HUD, the menu bar's health line, the announcement and the in-window panel.

private let quiet = RecordingAudioLevel(rms: 0.2, peak: 0.3)

private func surfaces(_ snapshot: RecordingHealthSnapshot) -> [(surface: String, line: String)] {
    var announcer = RecordingRiskAnnouncer()
    let menu = MenuBarRecording.make(
        isRecording: true, isStopping: false, elapsedSeconds: 10, canStartRecording: false,
        hasActiveTranscription: false, health: snapshot
    )
    let lines: [(String, String?)] = [
        ("banner", MenuBarRecording.riskBannerLine(isRecording: true, isStopping: false, health: snapshot)),
        ("HUD", RecordingHUD.make(isRecording: true, isStopping: false, elapsedSeconds: 10, health: snapshot, level: 0).topWarning),
        ("menu bar", menu.healthLine),
        ("announcement", announcer.announcement(for: snapshot)),
        ("health panel", RecordingHUD.failingWritesDetail(
            writeFailureCause: snapshot.writeFailureCause, unsavedTrack: snapshot.unsavedTrack
        )),
    ]
    return lines.map { ($0.0, $0.1 ?? "<nothing>") }
}

/// Ten seconds of buffers, ten a second, past the grace and staleness windows. Each track either
/// lands (`nil`) or fails every buffer with the given cause; `silentAfter` stops a landing track
/// from arriving at all after that time.
private func monitor(
    microphone: RecordingWriteFailureCause?,
    systemAudio: RecordingWriteFailureCause?,
    systemAudioSilentAfter: Double = .infinity
) -> RecordingHealthMonitor {
    let monitor = RecordingHealthMonitor(startedAt: 0)
    for tick in 1..<100 {
        let time = Double(tick) / 10
        if let microphone {
            monitor.recordWriteOutcome(.microphone, succeeded: false, cause: microphone)
        } else {
            monitor.recordWriteOutcome(.microphone, succeeded: true)
            monitor.receive(.microphone, level: quiet, at: time)
        }
        guard time <= systemAudioSilentAfter else { continue }
        if let systemAudio {
            monitor.recordWriteOutcome(.systemAudio, succeeded: false, cause: systemAudio)
        } else {
            monitor.recordWriteOutcome(.systemAudio, succeeded: true)
            monitor.receive(.systemAudio, level: quiet, at: time)
        }
    }
    return monitor
}

@Test("A microphone whose audio cannot be read is named, and nothing says to stop: the rest is still recording (F932)")
func oneUnreadableMicrophoneIsNamedWithoutStop() {
    let snapshot = monitor(microphone: .format, systemAudio: nil).snapshot(at: 10, availableStorageBytes: nil)

    #expect(snapshot.unsavedTrack == .microphone)
    #expect(snapshot.overallStatus == .atRisk, "still at risk: the microphone's audio is being lost")
    for (surface, line) in surfaces(snapshot) {
        #expect(line.contains("Microphone audio"), "\(surface): \(line)")
        #expect(line.contains("the rest is still recording"), "\(surface): \(line)")
        #expect(!line.lowercased().contains("stop"), "\(surface): stopping would end the audio still being saved — \(line)")
        #expect(!line.contains("disk space") && !line.contains("free space"), "\(surface): \(line)")
    }
    #expect(RecordingHUD.make(isRecording: true, isStopping: false, elapsedSeconds: 10, health: snapshot, level: 0).topWarning
            == "Microphone audio is not being saved — the rest is still recording")
}

@Test("System audio whose audio cannot be read is named the same way (F932)")
func oneUnreadableSystemTrackIsNamedWithoutStop() {
    let snapshot = monitor(microphone: nil, systemAudio: .format).snapshot(at: 10, availableStorageBytes: nil)

    #expect(snapshot.unsavedTrack == .systemAudio)
    for (surface, line) in surfaces(snapshot) {
        #expect(line.contains("System audio"), "\(surface): \(line)")
        #expect(line.contains("the rest is still recording"), "\(surface): \(line)")
        #expect(!line.lowercased().contains("stop"), "\(surface): \(line)")
    }
}

@Test("A full disk, where nothing is being saved, keeps F386's advice to stop and check disk space (F932)")
func aFullDiskStillSaysStop() {
    let snapshot = monitor(microphone: .storage, systemAudio: .storage).snapshot(at: 10, availableStorageBytes: nil)

    #expect(snapshot.unsavedTrack == nil, "both tracks are failing; nothing is being saved")
    for (surface, line) in surfaces(snapshot) {
        #expect(line.lowercased().contains("stop"), "\(surface): \(line)")
        #expect(line.contains("disk space") || line.contains("free space"), "\(surface): \(line)")
        #expect(!line.contains("the rest is still recording"), "\(surface): \(line)")
    }
}

@Test("Nothing is named, and stop stays, when the other track is not being saved either (F932)")
func noTrackIsNamedWhenNothingIsBeingSaved() {
    // Both tracks unreadable: F888's sentence, which keeps "stop".
    let both = monitor(microphone: .format, systemAudio: .format).snapshot(at: 10, availableStorageBytes: nil)
    #expect(both.unsavedTrack == nil)
    #expect(RecordingHUD.failingWritesDetail(writeFailureCause: both.writeFailureCause, unsavedTrack: both.unsavedTrack)
            .hasPrefix("Stop this recording"))

    // The microphone unreadable and system audio no longer arriving: nothing is being saved.
    let otherStopped = monitor(microphone: .format, systemAudio: nil, systemAudioSilentAfter: 2)
        .snapshot(at: 10, availableStorageBytes: nil)
    #expect(otherStopped.unsavedTrack == nil, "\(otherStopped.warnings)")
    #expect(RecordingHUD.message(
        .captureWritesFailing, writeFailureCause: otherStopped.writeFailureCause, unsavedTrack: otherStopped.unsavedTrack
    ) == "Audio is not being saved — stop the recording")

    // The microphone unreadable and no system audio ever heard: nothing is being saved either.
    let neverHeard = RecordingHealthMonitor(startedAt: 0)
    for _ in 0..<5 { neverHeard.recordWriteOutcome(.microphone, succeeded: false, cause: .format) }
    #expect(neverHeard.snapshot(at: 10, availableStorageBytes: nil).unsavedTrack == nil)
}

@Test("One track failing on the disk keeps the disk advice and the stop, since a disk filling up takes the other track next (F932)")
func oneTrackOnTheDiskKeepsTheDiskAdvice() {
    let snapshot = monitor(microphone: .storage, systemAudio: nil).snapshot(at: 10, availableStorageBytes: nil)

    #expect(snapshot.unsavedTrack == .microphone, "the fact is recorded whatever the cause")
    for (surface, line) in surfaces(snapshot) {
        #expect(line.contains("disk space") || line.contains("free space"), "\(surface): \(line)")
        #expect(line.lowercased().contains("stop"), "\(surface): \(line)")
    }
}
