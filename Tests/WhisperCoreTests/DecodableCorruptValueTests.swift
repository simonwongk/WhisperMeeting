import Foundation
import Testing
@testable import WhisperCore

// F462 — values that decode cleanly and then trap. Each fixture here is well-formed JSON of the
// right types, which is the whole point: no lenient decode, raw-string round-trip or quarantine can
// catch a number that is merely too big or too small, so the guard has to sit where the number is
// used. And each test asserts what the value READS as afterwards, not only that nothing crashed — a
// guard that clamps to a wrong number passes "did not crash" (AGENTS.md, the Int(Double) section).
//
// Part 3 (the link probe's size) needs `AppModel` and is in `WhisperMeetTests/LinkProbeSizeTests.swift`.

// MARK: - Part 1: a speaker number of Int.max

private func turn(_ start: Double, _ end: Double, _ cluster: Int) -> SpeakerTurn {
    SpeakerTurn(startSeconds: start, endSeconds: end, clusterID: cluster, kind: .speech)
}

private func sidecar(turns: [SpeakerTurn], aliases: [String: String] = [:]) -> DiarizationArtifactV1 {
    DiarizationArtifactV1(
        meetingID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        recording: DiarizationRecordingReference(relativePath: "Recordings/x/meeting.wav", sha256: "abc123", durationSeconds: 10),
        transcriptTimingFingerprint: "ffffffffffffffff",
        producer: DiarizationProducer(runtimeID: "fluidaudio", runtimeVersion: "0.15.7",
                                      segmentationModelSHA256: "seg", embeddingModelSHA256: "emb", clusterThreshold: 0.6),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        turns: turns,
        aliases: aliases
    )
}

/// The sidecar's bytes WITHOUT the codec's validation — what another build, an editor or a damaged
/// file can leave on disk — after checking that a plain decode accepts them, so the fixture is
/// "decodable but corrupt" and not merely malformed.
private func decodableBytes(_ artifact: DiarizationArtifactV1) throws -> Data {
    let data = try JSONEncoder.diarization.encode(artifact)
    let plain = try JSONDecoder.diarization.decode(DiarizationArtifactV1.self, from: data)
    try #require(plain == artifact, "the fixture must decode cleanly before the codec's own checks")
    return data
}

@Test("A speaker number past any the analysis assigns is refused, and the largest it assigns still reads (F462)")
func speakerNumberPastTheDenseRangeIsRefused() throws {
    // `anonymousSpeakerName` computes `clusterID + 1`, which traps at Int.max, and every speaker
    // label goes through it — so Int.max must never get past the gate. Nor the first number past the
    // bound: `densify` only ever numbers clusters 0..<n with n <= maximumClusterCount.
    for cluster in [Int.max, SpeakerTurns.maximumClusterCount] {
        #expect(throws: SpeakerTurnValidationError.clusterOutOfRange) {
            try SpeakerTurns.validate([turn(0, 5, cluster)], durationSeconds: 10)
        }
    }
    // The largest number the analysis does assign is untouched, and reads as the 64th speaker.
    let largest = SpeakerTurns.maximumClusterCount - 1
    let kept = try SpeakerTurns.validate([turn(0, 5, largest)], durationSeconds: 10)
    #expect(kept.map(\.clusterID) == [largest])
    #expect(TranscriptExporter.anonymousSpeakerName(clusterID: largest) == "Speaker 64")
    // And the refusal reads as a sentence about the analysis, like every other one (F227).
    #expect(SpeakerTurnValidationError.clusterOutOfRange.localizedDescription
            == "The speaker analysis was rejected: a turn was given a speaker number the analysis never assigns.")
}

@Test("A sidecar with a speaker number of Int.max is refused by the codec, not shown (F462)")
func sidecarWithIntMaxSpeakerIsRefused() throws {
    let data = try decodableBytes(sidecar(turns: [turn(0, 5, Int.max)]))
    #expect(String(decoding: data, as: UTF8.self).contains("9223372036854775807"))
    // Refused as malformed — what the app turns into "Speaker labels unavailable; your transcript is
    // safe" — rather than certified and handed to a renderer that adds one to it.
    #expect(throws: DiarizationArtifactError.malformed("clusterOutOfRange")) {
        try DiarizationArtifactCodec.decode(data)
    }
}

@Test("An alias key past the speaker numbers the analysis assigns is refused, and the largest one is kept (F462)")
func aliasKeyPastTheDenseRangeIsRefused() throws {
    for key in [String(Int.max), String(SpeakerTurns.maximumClusterCount)] {
        let data = try decodableBytes(sidecar(turns: [turn(0, 5, 0)], aliases: [key: "Ana"]))
        #expect(throws: DiarizationArtifactError.malformed("aliasKey"), "key \(key) was accepted") {
            try DiarizationArtifactCodec.decode(data)
        }
    }
    let largest = String(SpeakerTurns.maximumClusterCount - 1)
    let kept = try DiarizationArtifactCodec.decode(
        decodableBytes(sidecar(turns: [turn(0, 5, 0)], aliases: [largest: "Ana"]))
    )
    #expect(kept.aliases == [largest: "Ana"])
}

// MARK: - Part 2: an embeddings dimension that overflows the size check

private func temporaryDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("F462-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// `ask-embeddings.json` as `SegmentEmbeddings.write` lays it out, with the numbers a damaged file carries.
private func writeEmbeddingsSidecar(in directory: URL, texts: [String], dimension: Int, count: Int) throws {
    let metadata: [String: Any] = [
        "modelID": "test-model", "fingerprint": SegmentEmbeddings.fingerprint(of: texts),
        "dimension": dimension, "count": count,
    ]
    try JSONSerialization.data(withJSONObject: metadata)
        .write(to: directory.appendingPathComponent(SegmentEmbeddings.metadataFilename))
    try Data(repeating: 0, count: 16).write(to: directory.appendingPathComponent(SegmentEmbeddings.vectorsFilename))
}

@Test("An embeddings sidecar whose dimension overflows the size check reads as no index, not a crash (F462)")
func absurdEmbeddingDimensionReadsAsNoIndex() throws {
    let directory = try temporaryDirectory("embeddings")
    defer { try? FileManager.default.removeItem(at: directory) }
    // 2^62 × 1 fits an Int and the `× 4` bytes per float does not; Int.max overflows at once; and
    // 2 × 2^62 overflows at the first multiply. All three are positive, so `dimension > 0` passes.
    for (dimension, texts) in [(4_611_686_018_427_387_904, ["one"]),
                               (Int.max, ["one"]),
                               (4_611_686_018_427_387_904, ["one", "two"])] {
        try writeEmbeddingsSidecar(in: directory, texts: texts, dimension: dimension, count: texts.count)
        // nil is "no index": the meeting is searched by keyword and indexed again, as for a stale file.
        #expect(SegmentEmbeddings.read(from: directory, modelID: "test-model", texts: texts) == nil,
                "dimension \(dimension), count \(texts.count)")
    }

    // The control: a real index for the same texts still reads back exactly.
    let texts = ["one"]
    let index = SegmentEmbeddings(modelID: "test-model", fingerprint: SegmentEmbeddings.fingerprint(of: texts),
                                  dimension: 4, vectors: [0.5, -0.5, 0.25, 0.75])
    try index.write(to: directory)
    #expect(SegmentEmbeddings.read(from: directory, modelID: "test-model", texts: texts) == index)
}

/// A stand-in for the embedding helper: a `python` that writes the given metadata and 16 bytes of
/// vectors where `LocalEmbedder` asks for its output, the shape `LocalSummarizerTests` fakes.
private struct FakeEmbedderHelper {
    let root: URL
    let python: URL
    let helper: URL
    let model: URL

    init(metadataJSON: String) throws {
        root = try temporaryDirectory("embedder")
        python = root.appendingPathComponent("python")
        helper = root.appendingPathComponent("embed_local.py")
        model = root.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data().write(to: model.appendingPathComponent("model.safetensors"))
        try Data("# not run\n".utf8).write(to: helper)
        let script = """
        #!/bin/sh
        out=""
        while [ $# -gt 0 ]; do
          if [ "$1" = "--output" ]; then out="$2"; shift; fi
          shift
        done
        printf '%s' '\(metadataJSON)' > "$out.json"
        printf 'abcdabcdabcdabcd' > "$out"
        """
        try Data(script.utf8).write(to: python)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
    }

    var embedder: LocalEmbedder {
        LocalEmbedder(helperScriptURL: helper, pythonExecutableURL: python, modelDirectory: model)
    }
}

@Test("The embedder refuses a helper's answer whose dimension overflows the size check, not a crash (F462)")
func embedderRefusesAnOverflowingDimension() async throws {
    let fake = try FakeEmbedderHelper(metadataJSON: #"{"count":1,"dimension":4611686018427387904}"#)
    defer { try? FileManager.default.removeItem(at: fake.root) }
    await #expect(throws: LocalEmbedderError.unreadableOutput) {
        _ = try await fake.embedder.embed(["one"], kind: .passage)
    }

    // The control: the same 16 bytes described honestly are four floats.
    let honest = try FakeEmbedderHelper(metadataJSON: #"{"count":1,"dimension":4}"#)
    defer { try? FileManager.default.removeItem(at: honest.root) }
    let result = try await honest.embedder.embed(["one"], kind: .passage)
    #expect(result.dimension == 4)
    #expect(result.vectors.count == 4)
}

// MARK: - Part 4: a negative dictation-log limit

private func logEntry(_ index: Int) -> DictationLogEntry {
    DictationLogEntry(id: UUID(), date: Date(timeIntervalSince1970: 1_758_000_000 + Double(index)),
                      text: "entry \(index)", outcome: .pasted)
}

@Test("A negative persisted log limit keeps the default cap, keeps the history, and is written back as found (F462)")
func negativeDictationLogLimitKeepsTheDefaultCap() throws {
    for stored in [-1, Int.min] {
        let entries = (0..<3).map(logEntry)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // The file as a hand edit or a bad restore leaves it: well-formed, the right types.
        var object = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(DictationLog(entries: entries))) as? [String: Any]
        )
        object["limit"] = stored
        let log = try decoder.decode(DictationLog.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(log.limit == stored, "the fixture decodes cleanly, which is the point")

        // The next dictation is recorded, and nothing already in the history is lost.
        let updated = log.adding(logEntry(3))
        #expect(updated.entries.count == 4, "limit \(stored): \(updated.entries.count) entries kept")
        #expect(updated.entries.first?.text == "entry 3")
        #expect(updated.effectiveLimit == DictationLog.defaultLimit)

        // The cap that applies is the default one, so a full history rolls off at 100, not at 0 or 1.
        let full = DictationLog(entries: (0..<DictationLog.defaultLimit).map(logEntry), limit: stored)
        #expect(full.adding(logEntry(999)).entries.count == DictationLog.defaultLimit)

        // The stored value is a fact about the file, not this build's to rewrite (a later build may
        // have meant something by it), so it goes back to disk as it came.
        let written = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(updated)) as? [String: Any]
        )
        #expect((written["limit"] as? NSNumber)?.int64Value == Int64(stored))
    }
}

@Test("A log limit of zero still keeps nothing, and a positive one is still the cap (F462 control)")
func zeroAndPositiveLimitsAreUnchanged() {
    // Zero is not a trap — `removeLast(count - 0)` empties the log — and keeps its meaning.
    #expect(DictationLog(entries: [logEntry(0)], limit: 0).adding(logEntry(1)).entries.isEmpty)
    let capped = DictationLog(entries: (0..<5).map(logEntry), limit: 2).adding(logEntry(5))
    #expect(capped.entries.map(\.text) == ["entry 5", "entry 0"])
    #expect(capped.effectiveLimit == 2)
}
