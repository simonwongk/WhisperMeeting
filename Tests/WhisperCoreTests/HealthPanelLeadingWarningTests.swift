import Foundation
import Testing
@testable import WhisperCore

// F959 — the record screen's health panel led with `health.warnings.first`, the order
// `RecordingHealthMonitor.snapshot` appends in, while the HUD, the banner, the menu bar and the
// announcer lead with the lowest `RecordingHUD.rank`. The monitor appends `.systemAudioNotDetected`
// (a caution) before `.captureWritesFailing` (at risk), and clipping before low storage, so an
// in-person recording whose microphone's writes fail (reachable since F931) read "No system audio
// has been detected yet…" under a headline saying the recording needs attention. One selector,
// `RecordingHUD.leadingWarning(in:)`, now answers for every surface; the panel's call is pinned as
// source in `WhisperMeetTests/HealthPanelLeadingWarningSourceTests.swift`.

private let quiet = RecordingAudioLevel(rms: 0.2, peak: 0.3)

@Test("With no system audio yet and the microphone's writes failing, the panel's warning is the write failure, not the missing system audio (F959)")
func theWriteFailureLeadsTheMissingSystemAudio() {
    // Sixteen seconds past the system-audio detection grace, the microphone failing every buffer
    // on its format (F856's shape), system audio never delivered: the array the monitor builds.
    let monitor = RecordingHealthMonitor(startedAt: 0)
    for _ in 1..<160 {
        monitor.recordWriteOutcome(.microphone, succeeded: false, cause: .format)
    }
    let snapshot = monitor.snapshot(at: 16, availableStorageBytes: nil)

    #expect(snapshot.warnings == [.systemAudioNotDetected, .captureWritesFailing],
            "the fixture no longer builds the order the panel read: \(snapshot.warnings)")
    #expect(snapshot.overallStatus == .atRisk)
    #expect(RecordingHUD.leadingWarning(in: snapshot.warnings) == .captureWritesFailing)
    // The same answer the HUD gives for the same snapshot.
    let hud = RecordingHUD.make(isRecording: true, isStopping: false, elapsedSeconds: 16, health: snapshot, level: 0)
    #expect(hud.topWarning == RecordingHUD.message(
        .captureWritesFailing, writeFailureCause: snapshot.writeFailureCause, unsavedTrack: snapshot.unsavedTrack
    ))
}

@Test("The leading warning is the worst by rank, and the first of a tie, on every order the monitor can append in (F959)")
func theLeadingWarningIsTheWorstByRank() {
    // Clipping is appended before low storage.
    #expect(RecordingHUD.leadingWarning(in: [.microphoneClipping, .lowStorage]) == .lowStorage)
    #expect(RecordingHUD.leadingWarning(in: [.systemAudioClipping, .lowStorage, .systemAudioNotDetected]) == .lowStorage)
    // A tie keeps the first, as `RecordingHUD.topWarning` always has, so the panel and the HUD
    // cannot disagree about which of two rank-0 warnings leads.
    #expect(RecordingHUD.leadingWarning(in: [.microphoneCaptureStopped, .captureWritesFailing]) == .microphoneCaptureStopped)
    #expect(RecordingHUD.leadingWarning(in: [.captureWritesFailing, .microphoneCaptureStopped]) == .captureWritesFailing)
    #expect(RecordingHUD.leadingWarning(in: []) == nil)
    // Every warning alone leads itself.
    for warning in [RecordingHealthWarning.microphoneCaptureStopped, .systemAudioCaptureStopped, .systemAudioNotDetected,
                    .microphoneClipping, .systemAudioClipping, .lowStorage, .captureWritesFailing, .approachingLengthLimit] {
        #expect(RecordingHUD.leadingWarning(in: [warning]) == warning)
    }
}

@Test("The HUD's top warning is the leading warning's message, so the two selectors cannot drift (F959)")
func theHUDReadsTheSameSelector() {
    let warnings: [RecordingHealthWarning] = [.systemAudioNotDetected, .microphoneClipping, .captureWritesFailing, .lowStorage]
    let snapshot = RecordingHealthSnapshot(
        microphoneLevel: quiet, systemAudioLevel: .silent, availableStorageBytes: 1_000_000,
        warnings: warnings, writeFailureCause: .storage
    )
    let leading = RecordingHUD.leadingWarning(in: warnings)
    #expect(leading == .captureWritesFailing)
    #expect(RecordingHUD.topWarning(from: warnings, writeFailureCause: .storage, unsavedTrack: nil)
            == leading.map { RecordingHUD.message($0, writeFailureCause: .storage, unsavedTrack: nil) })
    #expect(RecordingHUD.make(isRecording: true, isStopping: false, elapsedSeconds: 1, health: snapshot, level: 0).topWarning
            == "Audio is not being saved — stop and check disk space")
}
