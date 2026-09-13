import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F218 — this sidecar holds user-typed aliases, so unlike notes.md it is NOT best-effort. Corrupt
// bytes are quarantined before anything overwrites them, a newer schema is left alone, a changed
// recording makes the result stale, and a read-only library refuses every mutation.

private func makeRecording() throws -> (root: URL, meetingID: UUID, directory: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiarizationStore-\(UUID().uuidString)", isDirectory: true)
    let meetingID = UUID()
    let directory = root.appendingPathComponent("Recordings/\(meetingID.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: directory.appendingPathComponent("meeting.wav"))
    return (root, meetingID, directory)
}

private func makeArtifact(meetingID: UUID, recordingHash: String = "hash-1") -> DiarizationArtifactV1 {
    DiarizationArtifactV1(
        meetingID: meetingID,
        recording: DiarizationRecordingReference(
            relativePath: "Recordings/\(meetingID.uuidString)/meeting.wav",
            sha256: recordingHash,
            durationSeconds: 10
        ),
        transcriptTimingFingerprint: "abc",
        producer: DiarizationProducer(
            runtimeID: "sherpa-onnx", runtimeVersion: "1.13.8",
            segmentationModelSHA256: "seg", embeddingModelSHA256: "emb", clusterThreshold: 0.3
        ),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        turns: [SpeakerTurn(startSeconds: 0, endSeconds: 5, clusterID: 0, kind: .speech)],
        aliases: [:]
    )
}

@Test("A saved artifact loads back identically (F218)")
func storeRoundTripsAnArtifact() throws {
    let (root, meetingID, _) = try makeRecording()
    defer { try? FileManager.default.removeItem(at: root) }
    let artifact = makeArtifact(meetingID: meetingID)

    try DiarizationArtifactStore.save(artifact, in: root)
    let outcome = DiarizationArtifactStore.load(meetingID: meetingID, in: root)

    guard case let .ready(loaded) = outcome else {
        Issue.record("expected .ready, got \(outcome)")
        return
    }
    #expect(loaded == artifact)
}

@Test("Loading when no sidecar exists reports absent, not an error (F218)")
func storeReportsAbsence() throws {
    let (root, meetingID, _) = try makeRecording()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(DiarizationArtifactStore.load(meetingID: meetingID, in: root) == .absent)
}

@Test("Corrupt bytes are quarantined and the original is left in place (F218)")
func storeQuarantinesCorruptBytes() throws {
    let (root, meetingID, directory) = try makeRecording()
    defer { try? FileManager.default.removeItem(at: root) }
    let sidecar = directory.appendingPathComponent("diarization.json")
    let corrupt = Data("{ this is not json".utf8)
    try corrupt.write(to: sidecar)

    let outcome = DiarizationArtifactStore.load(meetingID: meetingID, in: root)

    guard case .unavailable = outcome else {
        Issue.record("expected .unavailable, got \(outcome)")
        return
    }
    // Preserved, not destroyed — the bytes may be the only copy of a user's aliases.
    #expect(try Data(contentsOf: sidecar) == corrupt)
    let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(siblings.contains { $0.hasPrefix("diarization.unreadable-") })
}

@Test("A newer schema is preserved and never overwritten by a save (F218)")
func storeRefusesToClobberANewerSchema() throws {
    let (root, meetingID, directory) = try makeRecording()
    defer { try? FileManager.default.removeItem(at: root) }
    let sidecar = directory.appendingPathComponent("diarization.json")
    let future = Data(#"{"schemaVersion":99,"somethingNew":true}"#.utf8)
    try future.write(to: sidecar)

    let outcome = DiarizationArtifactStore.load(meetingID: meetingID, in: root)
    guard case .unavailable = outcome else {
        Issue.record("expected .unavailable, got \(outcome)")
        return
    }
    #expect(try Data(contentsOf: sidecar) == future)
    // A newer build's file is never quarantined either: it is not damaged, just unread here.
    let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(!siblings.contains { $0.hasPrefix("diarization.unreadable-") })
    // And a save must refuse rather than downgrade it, or a rerun on this build would silently
    // destroy whatever the newer schema was carrying.
    #expect(throws: (any Error).self) {
        try DiarizationArtifactStore.save(makeArtifact(meetingID: meetingID), in: root)
    }
    #expect(try Data(contentsOf: sidecar) == future)
}

@Test("An unreadable sidecar is copied aside before a save replaces it (F218)")
func storeQuarantinesBeforeOverwritingCorruptBytes() throws {
    let (root, meetingID, directory) = try makeRecording()
    defer { try? FileManager.default.removeItem(at: root) }
    let sidecar = directory.appendingPathComponent("diarization.json")
    let corrupt = Data("{ half-written aliases".utf8)
    try corrupt.write(to: sidecar)

    // Save without a preceding load: analysis may write straight through, and the bytes it lands on
    // may be the only copy of the aliases a person typed.
    try DiarizationArtifactStore.save(makeArtifact(meetingID: meetingID), in: root)

    let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    let quarantined = try #require(siblings.first { $0.hasPrefix("diarization.unreadable-") })
    #expect(try Data(contentsOf: directory.appendingPathComponent(quarantined)) == corrupt)
    #expect(try Data(contentsOf: sidecar) != corrupt)
}

@Test("A changed recording hash makes a loaded result stale rather than wrong (F218)")
func storeDetectsStaleAudio() throws {
    let (root, meetingID, _) = try makeRecording()
    defer { try? FileManager.default.removeItem(at: root) }
    try DiarizationArtifactStore.save(makeArtifact(meetingID: meetingID, recordingHash: "old"), in: root)

    let outcome = DiarizationArtifactStore.load(meetingID: meetingID, in: root, currentRecordingSHA256: "new")

    guard case .stale = outcome else {
        Issue.record("expected .stale, got \(outcome)")
        return
    }
}

@Test("Clearing removes only the sidecar and leaves the recording untouched (F218)")
func storeClearRemovesOnlyTheSidecar() throws {
    let (root, meetingID, directory) = try makeRecording()
    defer { try? FileManager.default.removeItem(at: root) }
    let wav = directory.appendingPathComponent("meeting.wav")
    let before = try Data(contentsOf: wav)
    try DiarizationArtifactStore.save(makeArtifact(meetingID: meetingID), in: root)

    try DiarizationArtifactStore.clear(meetingID: meetingID, in: root)

    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("diarization.json").path))
    #expect(try Data(contentsOf: wav) == before)
}

@Test("A save never touches the audio, and a failed save leaves the previous artifact intact (F218)")
func storeSaveIsAtomicAndNonDestructive() throws {
    let (root, meetingID, directory) = try makeRecording()
    defer { try? FileManager.default.removeItem(at: root) }
    let wav = directory.appendingPathComponent("meeting.wav")
    let audioBefore = try Data(contentsOf: wav)
    try DiarizationArtifactStore.save(makeArtifact(meetingID: meetingID, recordingHash: "first"), in: root)
    let firstBytes = try Data(contentsOf: directory.appendingPathComponent("diarization.json"))

    try DiarizationArtifactStore.save(makeArtifact(meetingID: meetingID, recordingHash: "second"), in: root)

    let secondBytes = try Data(contentsOf: directory.appendingPathComponent("diarization.json"))
    #expect(secondBytes != firstBytes)
    #expect(try Data(contentsOf: wav) == audioBefore)
    // No temp file is left behind.
    let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(!siblings.contains { $0.hasSuffix(".tmp") })
}

@Test("Saving into a missing recording directory fails rather than creating one (F218)")
func storeNeverCreatesARecordingFolder() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiarizationStore-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let meetingID = UUID()

    #expect(throws: (any Error).self) {
        try DiarizationArtifactStore.save(makeArtifact(meetingID: meetingID), in: root)
    }
    #expect(!FileManager.default.fileExists(
        atPath: root.appendingPathComponent("Recordings/\(meetingID.uuidString)").path))
}

@Test("The recording fingerprint streams rather than loading the whole file (F218)")
func recordingFingerprintStreamsLargeFiles() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiarizationHash-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("big.bin")
    // Several chunks' worth, so the chunk boundary logic is actually exercised.
    try Data(repeating: 0xAB, count: 5_000_000).write(to: file)

    let digest = try RecordingFingerprint.sha256(of: file)

    #expect(digest.count == 64)
    #expect(digest == (try RecordingFingerprint.sha256(of: file)))
}

@Test("The streamed fingerprint matches a whole-file digest byte for byte (F218)")
func recordingFingerprintMatchesWholeFileDigest() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiarizationHash-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // A known vector pins the chunked accumulation: "abc" hashes to the published SHA-256 digest,
    // so a chunking bug cannot hide behind a merely self-consistent result.
    let file = root.appendingPathComponent("abc.bin")
    try Data("abc".utf8).write(to: file)

    #expect(try RecordingFingerprint.sha256(of: file)
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

    let empty = root.appendingPathComponent("empty.bin")
    try Data().write(to: empty)
    #expect(try RecordingFingerprint.sha256(of: empty)
        == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
}
