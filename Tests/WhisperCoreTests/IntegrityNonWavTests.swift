import Foundation
import Testing
@testable import WhisperCore

// F143 — an imported non-WAV recording (kept in its original container) must not be flagged as a
// corrupt WAV; the integrity check applies WAV inspection only to .wav recordings.
@Test("Integrity check does not flag a non-WAV import as a corrupt WAV (F143)")
func integrityIgnoresNonWavContainers() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("IntegrityNonWav-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    // A non-empty .m4a with no RIFF/WAVE header.
    let m4a = dir.appendingPathComponent("meeting.m4a")
    try Data(repeating: 0x42, count: 8_192).write(to: m4a)

    let findings = MeetingIntegrityChecker.check(
        MeetingIntegrityDescriptor(recordingURL: m4a, sourceTracks: [], indexDurationSeconds: 120)
    )
    #expect(findings.isEmpty) // opaque container: existence + non-empty only, no WAV corruption claim
}

// F143 — a genuinely broken .wav is still flagged (regression guard).
@Test("Integrity check still flags an unreadable .wav header (F143 regression guard)")
func integrityStillFlagsBrokenWav() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("IntegrityWav-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let wav = dir.appendingPathComponent("meeting.wav")
    try Data(repeating: 0x00, count: 8_192).write(to: wav) // .wav extension but no valid header

    let findings = MeetingIntegrityChecker.check(
        MeetingIntegrityDescriptor(recordingURL: wav, sourceTracks: [], indexDurationSeconds: nil)
    )
    #expect(findings.contains { if case .wavHeaderUnreadable = $0 { return true }; return false })
}
