import Foundation
import Testing
@testable import WhisperCore

// F888 — "Audio is not being saved — stop and check disk space", whatever failed. Since F876 counts
// each track's failures on its own, the warning also fires for a track whose captured audio cannot
// be read at all: F856's unreadable format description, or F875's interleaved buffers before that
// fix. The disk is fine then, and the second clause sent the user to check it. The warning itself
// is right and stays; only the disk advice follows the cause the engine now reports with each
// failure.
//
// Every live surface that words the warning is read from one snapshot, so a surface that ignores
// the cause fails here rather than only the one a test happened to name.

private let quiet = RecordingAudioLevel(rms: 0.2, peak: 0.3)

/// Both channels heard at t = 1, and snapshots taken at t = 2: inside the 4 s grace period, so no
/// staleness warning competes with the one under test.
private func receivingMonitor() -> RecordingHealthMonitor {
    let monitor = RecordingHealthMonitor(startedAt: 0)
    monitor.receive(.systemAudio, level: quiet, at: 1)
    monitor.receive(.microphone, level: quiet, at: 1)
    return monitor
}

/// What each live surface says for this snapshot: the window's at-risk banner, the HUD, the menu
/// bar's health line, the spoken or posted announcement, and the in-window health panel.
private func surfaces(_ snapshot: RecordingHealthSnapshot) -> [(surface: String, line: String)] {
    var announcer = RecordingRiskAnnouncer()
    let menu = MenuBarRecording.make(
        isRecording: true, isStopping: false, elapsedSeconds: 5, canStartRecording: false,
        hasActiveTranscription: false, health: snapshot
    )
    let lines: [(String, String?)] = [
        ("banner", MenuBarRecording.riskBannerLine(isRecording: true, isStopping: false, health: snapshot)),
        ("HUD", RecordingHUD.make(isRecording: true, isStopping: false, elapsedSeconds: 5, health: snapshot, level: 0).topWarning),
        ("menu bar", menu.healthLine),
        ("announcement", announcer.announcement(for: snapshot)),
        ("health panel", RecordingHUD.failingWritesDetail(writeFailureCause: snapshot.writeFailureCause)),
    ]
    return lines.map { ($0.0, $0.1 ?? "<nothing>") }
}

private func failingMicrophone(_ cause: RecordingWriteFailureCause, times: Int = 5) -> RecordingHealthMonitor {
    let monitor = receivingMonitor()
    for _ in 0..<times {
        monitor.recordWriteOutcome(.microphone, succeeded: false, cause: cause)
        monitor.recordWriteOutcome(.systemAudio, succeeded: true)
    }
    return monitor
}

@Test("A track whose captured audio cannot be read raises the at-risk warning without the disk advice (F888)")
func formatFailuresDropTheDiskAdvice() {
    let snapshot = failingMicrophone(.format).snapshot(at: 2, availableStorageBytes: nil)

    #expect(snapshot.warnings.contains(.captureWritesFailing), "\(snapshot.warnings)")
    #expect(snapshot.overallStatus == .atRisk, "the warning itself stays: audio is still not being saved")
    #expect(snapshot.writeFailureCause == .format)
    for (surface, line) in surfaces(snapshot) {
        #expect(!line.contains("disk space") && !line.contains("free space"),
                "\(surface): the disk is not what failed — \(line)")
        #expect(line.contains("not being saved") || line.contains("no longer being written"), "\(surface): \(line)")
    }
}

@Test("A track whose writes fail on the disk keeps the disk advice (F888)")
func storageFailuresKeepTheDiskAdvice() {
    let snapshot = failingMicrophone(.storage).snapshot(at: 2, availableStorageBytes: nil)

    #expect(snapshot.writeFailureCause == .storage)
    for (surface, line) in surfaces(snapshot) {
        #expect(line.contains("disk space") || line.contains("free space"), "\(surface): \(line)")
    }
}

@Test("A failure reported without a cause reads as the disk's, as every failure did before (F888)")
func anUnattributedFailureIsStorage() {
    let monitor = receivingMonitor()
    for _ in 0..<3 { monitor.recordWriteOutcome(.systemAudio, succeeded: false) }
    #expect(monitor.snapshot(at: 2, availableStorageBytes: nil).writeFailureCause == .storage)
}

@Test("The disk advice goes only when every failing track's run is the format's (F888)")
func mixedCausesKeepTheDiskAdvice() {
    // One track on the disk, the other on its format: the disk may be full, so say so.
    let both = receivingMonitor()
    for _ in 0..<3 {
        both.recordWriteOutcome(.microphone, succeeded: false, cause: .format)
        both.recordWriteOutcome(.systemAudio, succeeded: false, cause: .storage)
    }
    #expect(both.snapshot(at: 2, availableStorageBytes: nil).writeFailureCause == .storage)

    // One track whose current run has a disk failure in it.
    let mixedRun = receivingMonitor()
    for cause in [RecordingWriteFailureCause.format, .storage, .format] {
        mixedRun.recordWriteOutcome(.microphone, succeeded: false, cause: cause)
    }
    #expect(mixedRun.snapshot(at: 2, availableStorageBytes: nil).writeFailureCause == .storage)

    // Both tracks on their format.
    let formatOnly = receivingMonitor()
    for _ in 0..<3 {
        formatOnly.recordWriteOutcome(.microphone, succeeded: false, cause: .format)
        formatOnly.recordWriteOutcome(.systemAudio, succeeded: false, cause: .format)
    }
    #expect(formatOnly.snapshot(at: 2, availableStorageBytes: nil).writeFailureCause == .format)
}

@Test("A track that recovers starts its cause over, and a track below the threshold has no say (F888)")
func theCauseFollowsTheCurrentRun() {
    let monitor = receivingMonitor()
    for _ in 0..<3 { monitor.recordWriteOutcome(.microphone, succeeded: false, cause: .storage) }
    #expect(monitor.snapshot(at: 2, availableStorageBytes: nil).writeFailureCause == .storage)
    // The disk came back; later the same track fails on its format instead.
    monitor.recordWriteOutcome(.microphone, succeeded: true)
    #expect(monitor.snapshot(at: 2, availableStorageBytes: nil).writeFailureCause == nil, "no warning, no cause")
    for _ in 0..<3 { monitor.recordWriteOutcome(.microphone, succeeded: false, cause: .format) }
    // Two disk failures on the other track are a blip (F386's threshold) and do not bring the
    // disk advice back.
    for _ in 0..<2 { monitor.recordWriteOutcome(.systemAudio, succeeded: false, cause: .storage) }
    #expect(monitor.snapshot(at: 2, availableStorageBytes: nil).writeFailureCause == .format)
}
