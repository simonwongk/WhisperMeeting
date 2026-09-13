import Foundation
import Testing
@testable import WhisperCore

// F218 — the sidecar is a new persistence contract holding user-typed aliases. It decodes strictly,
// refuses a newer schema rather than truncating it, and never silently repairs a malformed result.

private func artifact(
    turns: [SpeakerTurn] = [SpeakerTurn(startSeconds: 0, endSeconds: 5, clusterID: 0, kind: .speech)],
    aliases: [String: String] = [:]
) -> DiarizationArtifactV1 {
    DiarizationArtifactV1(
        meetingID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        recording: DiarizationRecordingReference(
            relativePath: "Recordings/x/meeting.wav",
            sha256: "abc123",
            durationSeconds: 10
        ),
        transcriptTimingFingerprint: "ffffffffffffffff",
        producer: DiarizationProducer(
            runtimeID: "sherpa-onnx",
            runtimeVersion: "1.13.8",
            segmentationModelSHA256: "seg",
            embeddingModelSHA256: "emb",
            clusterThreshold: 0.3
        ),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        turns: turns,
        aliases: aliases
    )
}

/// Every key in the encoded artifact, at every depth, sorted so an assertion over them is stable.
private func artifactKeys(in object: Any) -> [String] {
    var found: Set<String> = []
    func walk(_ value: Any) {
        if let dictionary = value as? [String: Any] {
            for (key, nested) in dictionary {
                found.insert(key)
                walk(nested)
            }
        } else if let array = value as? [Any] {
            array.forEach(walk)
        }
    }
    walk(object)
    return found.sorted()
}

@Test("An artifact round-trips through the codec unchanged (F218)")
func artifactRoundTrips() throws {
    let original = artifact(aliases: ["0": "Me"])
    let decoded = try DiarizationArtifactCodec.decode(DiarizationArtifactCodec.encode(original))
    #expect(decoded == original)
}

@Test("The encoded form is stable, sorted JSON with ISO-8601 dates (F218)")
func artifactEncodesStably() throws {
    let data = try DiarizationArtifactCodec.encode(artifact())
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("\"schemaVersion\" : 1"))
    #expect(text.contains("2023-11-14T"))
    // Sorted keys mean a byte-identical re-encode of unchanged content — no spurious rewrites.
    let again = try DiarizationArtifactCodec.encode(artifact())
    #expect(again == data)
}

@Test("A newer schema version is refused, not truncated (F218)")
func artifactRefusesNewerSchema() throws {
    var object = try #require(
        try JSONSerialization.jsonObject(with: DiarizationArtifactCodec.encode(artifact())) as? [String: Any]
    )
    object["schemaVersion"] = 2
    let data = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: DiarizationArtifactError.newerSchema(2)) {
        try DiarizationArtifactCodec.decode(data)
    }
}

@Test("Corrupt bytes decode as unreadable (F218)")
func artifactRefusesCorruptBytes() {
    #expect(throws: DiarizationArtifactError.unreadable) {
        try DiarizationArtifactCodec.decode(Data("not json at all".utf8))
    }
}

@Test("A malformed turn fails the whole decode rather than being dropped (F218)")
func artifactValidatesTurnsOnDecode() throws {
    let bad = artifact(turns: [SpeakerTurn(startSeconds: 5, endSeconds: 1, clusterID: 0, kind: .speech)])
    // Encoding does not validate; decoding must, because the file may have been written by anything.
    let data = try JSONEncoder.diarization.encode(bad)
    var thrown: Error?
    do { _ = try DiarizationArtifactCodec.decode(data) } catch { thrown = error }
    #expect(thrown as? DiarizationArtifactError == .malformed("reversedInterval"))
}

@Test("A turn past the recorded duration fails the decode (F218)")
func artifactValidatesTurnsAgainstItsOwnDuration() throws {
    let bad = artifact(turns: [SpeakerTurn(startSeconds: 0, endSeconds: 99, clusterID: 0, kind: .speech)])
    let data = try JSONEncoder.diarization.encode(bad)
    #expect(throws: DiarizationArtifactError.malformed("exceedsDuration")) {
        try DiarizationArtifactCodec.decode(data)
    }
}

@Test("An alias key that is not a cluster number is refused (F218)")
func artifactRefusesNonNumericAliasKeys() throws {
    let bad = artifact(aliases: ["not-a-number": "Me"])
    let data = try JSONEncoder.diarization.encode(bad)
    #expect(throws: DiarizationArtifactError.malformed("aliasKey")) {
        try DiarizationArtifactCodec.decode(data)
    }
}

@Test("An over-long alias is refused so the sidecar cannot become a text dump (F218)")
func artifactBoundsAliasLength() throws {
    let bad = artifact(aliases: ["0": String(repeating: "a", count: DiarizationArtifactV1.maximumAliasLength + 1)])
    let data = try JSONEncoder.diarization.encode(bad)
    #expect(throws: DiarizationArtifactError.malformed("aliasLength")) {
        try DiarizationArtifactCodec.decode(data)
    }
}

@Test("The artifact carries no embedding, audio, or transcript text (F218)")
func artifactCarriesNoVoiceData() throws {
    let data = try DiarizationArtifactCodec.encode(artifact(aliases: ["0": "Me"]))
    let text = String(decoding: data, as: UTF8.self).lowercased()
    for forbidden in ["voiceprint", "spectrogram", "waveform", "samples", "pcm"] {
        #expect(!text.contains(forbidden), "artifact leaked a \(forbidden) field")
    }
    // "embedding", "transcript" and "text" get a key-level check instead of a substring scan,
    // because two legitimate provenance fields name them: `embeddingModelSHA256` (the hash of the
    // model file, never a voice vector) and `transcriptTimingFingerprint` (a digest of timings,
    // never words). Exactly those two may exist; any other key naming an embedding, a transcript,
    // audio, a voice or text would mean voice data or copied words landed in the sidecar.
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let keys = artifactKeys(in: object)
    #expect(keys.filter { $0.lowercased().contains("embedding") } == ["embeddingModelSHA256"])
    #expect(keys.filter { $0.lowercased().contains("transcript") } == ["transcriptTimingFingerprint"])
    for leak in ["text", "audio", "voice", "sample"] {
        #expect(!keys.contains { $0.lowercased().contains(leak) }, "artifact leaked a \(leak) field")
    }
    // Both are fixed-width digests, so a bounded length is what stops either from being widened
    // into a carrier for the data it is named after.
    let producer = try #require(object["producer"] as? [String: Any])
    let embeddingHash = try #require(producer["embeddingModelSHA256"] as? String)
    #expect(embeddingHash.count <= 64)
    let fingerprint = try #require(object["transcriptTimingFingerprint"] as? String)
    #expect(fingerprint.count <= 32 && fingerprint.allSatisfy(\.isHexDigit))
}

@Test("A fingerprint or digest widened into a carrier for voice data is refused (F218)")
func artifactBoundsItsDigestFields() throws {
    // The privacy promise is "no voice data, no copied transcript text". Two fields are named after
    // exactly those things; only a bound in the CODEC keeps them from becoming carriers for them.
    // Asserting the bound on a fixture this file hardcodes asserts the fixture, not the codec.
    var object = try #require(
        try JSONSerialization.jsonObject(with: DiarizationArtifactCodec.encode(artifact())) as? [String: Any]
    )
    object["transcriptTimingFingerprint"] = String(repeating: "So then he said we should ship it. ", count: 40)
    #expect(throws: DiarizationArtifactError.malformed("fingerprint")) {
        try DiarizationArtifactCodec.decode(try JSONSerialization.data(withJSONObject: object))
    }

    object["transcriptTimingFingerprint"] = "ffffffffffffffff"
    var producer = try #require(object["producer"] as? [String: Any])
    producer["embeddingModelSHA256"] = String(repeating: "A", count: 4_096)   // a voice vector
    object["producer"] = producer
    #expect(throws: DiarizationArtifactError.malformed("digest")) {
        try DiarizationArtifactCodec.decode(try JSONSerialization.data(withJSONObject: object))
    }

    // And the digest bound counts BYTES, for the same reason the alias bound does: one Character can
    // be tens of kilobytes of combining marks, so 32 of them pass any grapheme-count bound while
    // carrying more than a megabyte.
    producer["embeddingModelSHA256"] = String(
        repeating: "a" + String(repeating: "\u{0301}", count: 20_000), count: 32
    )
    object["producer"] = producer
    #expect(throws: DiarizationArtifactError.malformed("digest")) {
        try DiarizationArtifactCodec.decode(try JSONSerialization.data(withJSONObject: object))
    }
}

@Test("The codec refuses to write a file it would then refuse to read (F218)")
func artifactEncodeIsAsStrictAsDecode() throws {
    // "Strict read/write" is the header's claim, and AppModel writes every analysis through this
    // function. An encode that accepts what decode rejects persists a failed analysis happily and
    // fails on the NEXT read — reaching the user as a corrupt sidecar, a launch later and far from
    // the cause, rather than as an analysis that did not finish.
    let bad = artifact(turns: [SpeakerTurn(startSeconds: 0, endSeconds: 99, clusterID: 0, kind: .speech)])
    #expect(throws: DiarizationArtifactError.malformed("exceedsDuration")) {
        try DiarizationArtifactCodec.encode(bad)
    }
    #expect(throws: DiarizationArtifactError.malformed("aliasKey")) {
        try DiarizationArtifactCodec.encode(artifact(aliases: ["not-a-number": "Ada"]))
    }
}

@Test("An alias of combining marks cannot smuggle megabytes past the length bound (F218)")
func artifactBoundsAliasBytesNotJustCharacters() throws {
    // `.count` is grapheme clusters, and one Character can be tens of kilobytes of combining marks.
    // "64 characters" is therefore not a bound at all on a file that may have been written by
    // anything — which is the whole premise of decoding strictly.
    let oneCharacter = "a" + String(repeating: "\u{0301}", count: 20_000)
    let alias = String(repeating: oneCharacter, count: 64)
    #expect(alias.count == DiarizationArtifactV1.maximumAliasLength)   // passes a count-only bound
    #expect(alias.utf8.count > 2_000_000)                              // while carrying 2.5 MB
    let data = try JSONEncoder.diarization.encode(artifact(aliases: ["0": alias]))
    // Caught rather than `#expect(throws:)` so a failure reports the error, not 2.5 MB of alias.
    var thrown: Error?
    do { _ = try DiarizationArtifactCodec.decode(data) } catch { thrown = error }
    #expect(thrown as? DiarizationArtifactError == .malformed("aliasLength"))
}

@Test("No decode failure escapes the codec as anything but a DiarizationArtifactError (F218)")
func artifactDecodeFailuresAreAlwaysArtifactErrors() throws {
    // `DiarizationArtifactStore.load` quarantines whatever escapes `decode`, so an error type the
    // codec forgot to convert files a PERFECTLY GOOD sidecar away as corrupt — a validation bug
    // becomes data loss. The conversion has to be exhaustive, not one typed arm that happens to
    // cover everything `SpeakerTurns.validate` throws today.
    let fixtures = [
        artifact(turns: [SpeakerTurn(startSeconds: 5, endSeconds: 1, clusterID: 0, kind: .speech)]),
        artifact(turns: [SpeakerTurn(startSeconds: 0, endSeconds: 99, clusterID: 0, kind: .speech)]),
        artifact(turns: [SpeakerTurn(startSeconds: 0, endSeconds: 1, clusterID: -1, kind: .speech)]),
        artifact(turns: [
            SpeakerTurn(startSeconds: 2, endSeconds: 3, clusterID: 0, kind: .speech),
            SpeakerTurn(startSeconds: 1, endSeconds: 2, clusterID: 1, kind: .speech)
        ])
    ]
    for bad in fixtures {
        let data = try JSONEncoder.diarization.encode(bad)
        var thrown: Error?
        do { _ = try DiarizationArtifactCodec.decode(data) } catch { thrown = error }
        #expect(thrown is DiarizationArtifactError, "escaped as \(String(describing: thrown))")
    }
}
