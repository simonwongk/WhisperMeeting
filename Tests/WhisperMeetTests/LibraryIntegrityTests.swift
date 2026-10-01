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

/// F505: Verify Library's header counted finding LINES as recordings, so one meeting with three
/// findings was reported as "problems with 3 recordings". The header counts meetings; every finding
/// line stays in the body.
@MainActor
@Test("Verify Library's header counts recordings with problems, not findings (F505)")
func verifyLibraryHeaderCountsRecordingsNotFindings() throws {
    let root = try makeTempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = headyModel(root: root)

    let manyID = UUID()
    model.store.upsert(MeetingRecord(id: manyID, title: "Three findings",
                                     recordingPath: "Recordings/\(manyID.uuidString)/meeting.wav"))
    let threeFindings: [IntegrityFinding] = [
        .wavTruncated(declaredBytes: 1_000, actualBytes: 144),
        .durationInconsistent(headerSeconds: 10, indexSeconds: 30),
        .sourceTrackFrameMismatch(track: "system", expectedFrames: 480_000, actualFrames: 1),
    ]
    model.checkMeetingIntegrity = { _ in threeFindings }

    model.verifyLibrary()

    let single = try #require(model.alertMessage)
    #expect(single.hasPrefix("Library check found problems with 1 recording."))
    // Header plus one paragraph per finding: nothing was dropped from the body.
    #expect(single.components(separatedBy: "\n\n").count == 1 + 3)

    // Two meetings, with three findings and one finding: two recordings, four lines.
    let oneID = UUID()
    model.store.upsert(MeetingRecord(id: oneID, title: "One finding",
                                     recordingPath: "Recordings/\(oneID.uuidString)/meeting.wav"))
    model.checkMeetingIntegrity = { descriptor in
        descriptor.recordingURL.path.contains(oneID.uuidString) ? [.recordingMissing] : threeFindings
    }
    model.alertMessage = nil

    model.verifyLibrary()

    let pair = try #require(model.alertMessage)
    #expect(pair.hasPrefix("Library check found problems with 2 recordings."))
    #expect(pair.components(separatedBy: "\n\n").count == 1 + 4)
}

// MARK: - F638: raw tracks with no description are reported as unchecked, not silently skipped

/// A capture folder: a complete canonical WAV plus both raw `.f32` tracks, and no manifest unless
/// the caller writes one.
private func makeCaptureFolder(_ id: UUID, in root: URL) throws -> URL {
    let dir = try makeMeetingDirectory(id, in: root)
    try (wavHeader(sampleRate: 16_000, channels: 1, bitsPerSample: 16, dataBytes: 32_000)
        + Data(count: 32_000)).write(to: dir.appendingPathComponent("meeting.wav"))
    try Data(count: 16_000 * MemoryLayout<Float>.size).write(to: dir.appendingPathComponent("system-audio.f32"))
    try Data(count: 16_000 * MemoryLayout<Float>.size).write(to: dir.appendingPathComponent("microphone-audio.f32"))
    return dir
}

/// F638: when `source-tracks.json` could not be written after a complete mix (F502 made that write
/// best-effort), the folder is indexed and never gets one, and Verify Library skipped the raw-track
/// check without a word — the report said "no audio problems" about tracks it had not looked at.
/// Asked for explicitly, the check now says those tracks were not checked. A capture folder that
/// has its manifest, and an import that has no raw tracks at all, say nothing.
@MainActor
@Test("Verify Library says a capture's raw tracks were not checked when their manifest is missing (F638)")
func verifyLibraryReportsRawTracksWithoutAManifest() throws {
    let root = try makeTempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = headyModel(root: root)

    let unmanifestedID = UUID()
    _ = try makeCaptureFolder(unmanifestedID, in: root)

    let manifestedID = UUID()
    let manifestedDir = try makeCaptureFolder(manifestedID, in: root)
    try writeSourceManifest(systemFrames: 16_000, microphoneFrames: 16_000, in: manifestedDir)

    let importedID = UUID()
    let importedDir = try makeMeetingDirectory(importedID, in: root)
    try (wavHeader(sampleRate: 16_000, channels: 1, bitsPerSample: 16, dataBytes: 32_000)
        + Data(count: 32_000)).write(to: importedDir.appendingPathComponent("meeting.wav"))

    func record(_ id: UUID, _ title: String) -> MeetingRecord {
        MeetingRecord(id: id, title: title, recordingPath: "Recordings/\(id.uuidString)/meeting.wav", status: .completed)
    }
    model.store.upsert(record(unmanifestedID, "Unchecked tracks"))
    model.store.upsert(record(manifestedID, "Described tracks"))
    model.store.upsert(record(importedID, "Imported file"))

    model.verifyLibrary()

    let message = try #require(model.alertMessage)
    // The note is not a problem with the recording, so a library whose only entry is the note is
    // not told it has "problems" — the header counts it as not fully checked instead.
    #expect(message.hasPrefix("Library check found no audio problems, but 1 recording could not be fully checked."))
    #expect(!message.contains("found problems with"))
    #expect(message.contains("“Unchecked tracks”"))
    #expect(message.contains("source-tracks.json"))
    #expect(!message.contains("Described tracks"))
    #expect(!message.contains("Imported file"))

    // Read-only: the check describes the gap, it does not fill it with invented alignment.
    let unmanifestedDir = root.appendingPathComponent("Recordings/\(unmanifestedID.uuidString)", isDirectory: true)
    #expect(!FileManager.default.fileExists(atPath: unmanifestedDir.appendingPathComponent("source-tracks.json").path))
    #expect(!FileManager.default.fileExists(atPath: unmanifestedDir.appendingPathComponent("source-tracks.recovered.json").path))
}

/// F638 with F505: the header still counts recordings, not lines (F505), but it counts a recording as
/// having problems only for a finding that is one. The unchecked-tracks note says what the check
/// could not look at; counted as a problem it told a user with nothing wrong that their library had
/// problems. Recordings carrying the note are counted separately, as not fully checked.
@MainActor
@Test("Verify Library's header counts only recordings with problems, and words unchecked tracks as a note (F638, F505)")
func verifyLibraryHeaderCountsOnlyRecordingsWithProblems() throws {
    let root = try makeTempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = headyModel(root: root)

    let firstID = UUID()
    let secondID = UUID()
    model.store.upsert(MeetingRecord(id: firstID, title: "First",
                                     recordingPath: "Recordings/\(firstID.uuidString)/meeting.wav"))
    model.store.upsert(MeetingRecord(id: secondID, title: "Second",
                                     recordingPath: "Recordings/\(secondID.uuidString)/meeting.wav"))

    // Notes only, on two recordings: no problems, two not fully checked, both lines kept.
    model.checkMeetingIntegrity = { _ in [.sourceTrackManifestMissing] }
    model.verifyLibrary()

    let notesOnly = try #require(model.alertMessage)
    #expect(notesOnly.hasPrefix(
        "Library check found no audio problems, but 2 recordings could not be fully checked. The recordings were not changed."
    ))
    #expect(notesOnly.components(separatedBy: "\n\n").count == 1 + 2)

    // A problem and the note on the first, the note alone on the second: one recording with
    // problems, two not fully checked, three lines.
    model.checkMeetingIntegrity = { descriptor in
        descriptor.recordingURL.path.contains(firstID.uuidString)
            ? [.wavTruncated(declaredBytes: 1_000, actualBytes: 144), .sourceTrackManifestMissing]
            : [.sourceTrackManifestMissing]
    }
    model.alertMessage = nil
    model.verifyLibrary()

    let mixed = try #require(model.alertMessage)
    #expect(mixed.hasPrefix(
        "Library check found problems with 1 recording, and 2 recordings could not be fully checked. The recordings were not changed."
    ))
    #expect(mixed.components(separatedBy: "\n\n").count == 1 + 3)
}

/// F638, the other half of the choice: the launch sweep reports damage, and a missing description
/// is neither damage nor something the user can clear, so it is left to the Verify Library button
/// rather than repeated in the startup notice on every launch.
@MainActor
@Test("The launch sweep does not repeat the unchecked-raw-tracks note on every launch (F638)")
func launchSweepLeavesUncheckedRawTracksToVerifyLibrary() async throws {
    let root = try makeTempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = headyModel(root: root)

    let id = UUID()
    _ = try makeCaptureFolder(id, in: root)
    model.store.upsert(MeetingRecord(id: id, title: "Unchecked tracks",
                                     recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
                                     status: .completed))

    await model.performStartupRecovery()

    #expect(model.alertMessage?.contains("Unchecked tracks") != true)
    #expect(model.verifyLibraryIntegrity().isEmpty)
}
