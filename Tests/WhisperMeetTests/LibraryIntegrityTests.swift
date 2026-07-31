import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F83 — the library-integrity sweep is wired onto AppModel so the tested F66 core
// (MeetingIntegrityChecker / WAVInspection) becomes reachable from the running app. These tests
// drive the app-level call over a real on-disk fixture library, never a real user meeting.

/// A canonical 44-byte 16-bit-PCM WAV header declaring `dataBytes` of audio (F83 fixtures).
private func wavHeader(sampleRate: UInt32, channels: UInt16, bitsPerSample: UInt16, dataBytes: UInt32) -> Data {
    var data = Data()
    func append32(_ v: UInt32) { data.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
    func append16(_ v: UInt16) { data.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
    data.append(contentsOf: Array("RIFF".utf8)); append32(36 + dataBytes)
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); append32(16)
    append16(1) /* PCM */; append16(channels); append32(sampleRate)
    append32(sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8) /* byte rate */
    append16(channels * bitsPerSample / 8) /* block align */; append16(bitsPerSample)
    data.append(contentsOf: Array("data".utf8)); append32(dataBytes)
    return data
}

/// Writes a `source-tracks.json` next to a meeting.wav declaring the given per-track frame counts,
/// matching the manifest shape `AudioCaptureEngine` emits (F83 fixtures).
private func writeSourceManifest(systemFrames: Int64, microphoneFrames: Int64, in directory: URL) throws {
    let json = """
    {
      "microphoneAudio": {"channels": 1, "file": "microphone-audio.f32", "format": "float32-little-endian", "frameCount": \(microphoneFrames), "sampleRate": 48000, "startOffsetSeconds": 0},
      "systemAudio": {"channels": 1, "file": "system-audio.f32", "format": "float32-little-endian", "frameCount": \(systemFrames), "sampleRate": 48000, "startOffsetSeconds": 0}
    }
    """
    try Data(json.utf8).write(to: directory.appendingPathComponent("source-tracks.json"))
}

private func makeTempLibrary() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LibraryIntegrityTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Recordings", isDirectory: true),
        withIntermediateDirectories: true
    )
    return root
}

/// Creates `Recordings/<id>/` and returns its directory; the caller populates meeting.wav / tracks.
private func makeMeetingDirectory(_ id: UUID, in root: URL) throws -> URL {
    let dir = root.appendingPathComponent("Recordings", isDirectory: true)
        .appendingPathComponent(id.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@MainActor
private func headyModel(root: URL) -> AppModel {
    let suite = "WhisperMeet.LibraryIntegrityTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
}

private func hasTruncation(_ findings: [IntegrityFinding]) -> Bool {
    findings.contains { if case .wavTruncated = $0 { return true }; return false }
}

private func hasFrameMismatch(_ findings: [IntegrityFinding]) -> Bool {
    findings.contains { if case .sourceTrackFrameMismatch = $0 { return true }; return false }
}

/// The headline reachability test: a fixture library with a truncated WAV and a frame-mismatched
/// .f32 must produce the expected IntegrityFindings THROUGH the app-level call (F83), not a direct
/// MeetingIntegrityChecker call.
@MainActor
@Test("Library integrity sweep flags a truncated WAV and a frame-mismatched source track through the app-level call (F83)")
func libraryIntegritySweepFlagsCorruptMeetingsThroughAppCall() throws {
    let root = try makeTempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = headyModel(root: root)

    // Healthy: a real synthetic bench clip stands in for a good recording — use Scripts/bench/clips,
    // never a real meeting. Falls back to a synthesized canonical WAV if the clip is unavailable.
    let healthyID = UUID()
    let healthyDir = try makeMeetingDirectory(healthyID, in: root)
    let benchClip = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Scripts/bench/clips/en1.wav")
    let healthyWav = healthyDir.appendingPathComponent("meeting.wav")
    if FileManager.default.fileExists(atPath: benchClip.path) {
        try FileManager.default.copyItem(at: benchClip, to: healthyWav)
    } else {
        try (wavHeader(sampleRate: 16_000, channels: 1, bitsPerSample: 16, dataBytes: 32_000)
            + Data(count: 32_000)).write(to: healthyWav)
    }

    // Truncated: the header declares 32000 data bytes but only 100 are present.
    let truncatedID = UUID()
    let truncatedDir = try makeMeetingDirectory(truncatedID, in: root)
    try (wavHeader(sampleRate: 16_000, channels: 1, bitsPerSample: 16, dataBytes: 32_000)
        + Data(count: 100)).write(to: truncatedDir.appendingPathComponent("meeting.wav"))

    // Frame mismatch: a healthy WAV, but the system .f32 is shorter than its manifest frameCount.
    let mismatchID = UUID()
    let mismatchDir = try makeMeetingDirectory(mismatchID, in: root)
    try (wavHeader(sampleRate: 16_000, channels: 1, bitsPerSample: 16, dataBytes: 32_000)
        + Data(count: 32_000)).write(to: mismatchDir.appendingPathComponent("meeting.wav"))
    try Data(count: 100 * MemoryLayout<Float>.size).write(to: mismatchDir.appendingPathComponent("system-audio.f32"))
    try Data(count: 0).write(to: mismatchDir.appendingPathComponent("microphone-audio.f32"))
    try writeSourceManifest(systemFrames: 16_000, microphoneFrames: 0, in: mismatchDir)

    func record(_ id: UUID, _ title: String) -> MeetingRecord {
        MeetingRecord(id: id, title: title, recordingPath: "Recordings/\(id.uuidString)/meeting.wav", status: .completed)
    }
    model.store.upsert(record(healthyID, "Healthy"))
    model.store.upsert(record(truncatedID, "Truncated"))
    model.store.upsert(record(mismatchID, "Frame mismatch"))

    let results = model.verifyLibraryIntegrity()

    #expect(results.count == 2)
    #expect(results.contains { $0.meeting.id == truncatedID && hasTruncation($0.findings) })
    #expect(results.contains { $0.meeting.id == mismatchID && hasFrameMismatch($0.findings) })
    #expect(!results.contains { $0.meeting.id == healthyID })

    // The recording files are read-only inputs — the sweep must never resize or delete them.
    #expect(FileManager.default.fileExists(atPath: healthyWav.path))
    let truncatedSize = (try FileManager.default.attributesOfItem(atPath: truncatedDir.appendingPathComponent("meeting.wav").path)[.size] as? Int) ?? -1
    #expect(truncatedSize == 144) // 44-byte header + 100 data bytes, unchanged by the check
}

/// The primary reachability path: on launch, `performStartupRecovery` runs the sweep and surfaces
/// findings through the same alert as recovery, without ever touching the audio (F83).
@MainActor
@Test("Integrity findings surface through startup recovery's alert without touching audio (F83)")
func integrityFindingsSurfaceThroughStartupRecovery() async throws {
    let root = try makeTempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = headyModel(root: root)

    let truncatedID = UUID()
    let dir = try makeMeetingDirectory(truncatedID, in: root)
    let wav = dir.appendingPathComponent("meeting.wav")
    try (wavHeader(sampleRate: 16_000, channels: 1, bitsPerSample: 16, dataBytes: 32_000)
        + Data(count: 100)).write(to: wav)
    model.store.upsert(MeetingRecord(id: truncatedID, title: "Corrupt meeting",
                                     recordingPath: "Recordings/\(truncatedID.uuidString)/meeting.wav",
                                     status: .completed))

    await model.performStartupRecovery()

    #expect(model.alertMessage?.contains("Corrupt meeting") == true)
    #expect(model.alertMessage?.contains("truncated") == true)
    // The recording is a read-only input — the launch sweep must not resize or delete it.
    let size = (try FileManager.default.attributesOfItem(atPath: wav.path)[.size] as? Int) ?? -1
    #expect(size == 144)
}

/// The wiring is driven through the injected checker seam (mirroring F47), and meetings with no
/// recording are skipped rather than reported (F83).
@MainActor
@Test("Library sweep routes findings through the injected checker seam and skips recording-less meetings (F83)")
func libraryIntegritySweepUsesInjectedSeamAndSkipsRecordinglessMeetings() throws {
    let root = try makeTempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = headyModel(root: root)

    let withRecordingID = UUID()
    model.store.upsert(MeetingRecord(id: withRecordingID, title: "Has audio",
                                     recordingPath: "Recordings/\(withRecordingID.uuidString)/meeting.wav"))
    model.store.upsert(MeetingRecord(id: UUID(), title: "No audio", recordingPath: ""))

    // Inject a fake checker: proves the sweep goes through the seam and collects its findings.
    model.checkMeetingIntegrity = { _ in [.recordingMissing] }

    let results = model.verifyLibraryIntegrity()

    #expect(results.count == 1) // the recording-less meeting was skipped, not reported
    #expect(results.first?.meeting.id == withRecordingID)
    #expect(results.first?.findings == [.recordingMissing])
}
