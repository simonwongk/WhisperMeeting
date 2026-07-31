import Foundation
import Testing
@testable import WhisperCore

/// F58 — the post-meeting health report folded across the capture.
@Test("Health report folds warnings, worst status, and mic stale seconds")
func recordingHealthReport() {
    let monitor = RecordingHealthMonitor(
        startedAt: 0, initialGracePeriod: 0, staleAfter: 3, systemDetectionGracePeriod: 0
    )
    monitor.receive(.microphone, level: RecordingAudioLevel(rms: 0.3, peak: 0.4), at: 0)

    _ = monitor.snapshot(at: 2, availableStorageBytes: nil)  // mic fresh; system never detected
    _ = monitor.snapshot(at: 6, availableStorageBytes: nil)  // mic now stale (6-0 > 3); +4s
    _ = monitor.snapshot(at: 10, availableStorageBytes: nil) // still stale; +4s

    let report = monitor.report()

    #expect(report.warnings.contains(.systemAudioNotDetected))
    #expect(report.worstStatus == .atRisk) // microphone capture stopped is at-risk
    #expect(report.microphoneStaleSeconds == 8)
    #expect(!report.systemAudioEverDetected)
}

@Test("A RecordingHealthReport round-trips through Codable")
func healthReportCodable() throws {
    let report = RecordingHealthReport(
        warnings: [.systemAudioNotDetected, .lowStorage],
        worstStatus: .atRisk,
        microphoneStaleSeconds: 3,
        systemAudioStaleSeconds: 0,
        systemAudioEverDetected: false
    )
    let data = try JSONEncoder().encode(report)
    let decoded = try JSONDecoder().decode(RecordingHealthReport.self, from: data)
    #expect(decoded == report)
}
