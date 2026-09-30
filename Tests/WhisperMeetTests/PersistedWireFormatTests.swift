import Foundation
import Testing
@testable import WhisperCore

// F544 — F304's "every stored field reaches the wire" guard, extended past `MeetingRecord`.
//
// A hand-written `CodingKeys` means Swift encodes ONLY the listed keys, and a hand-written
// `encode(to:)` writes only what it names. A stored property added without touching either
// compiles, decodes as its default, and is silently dropped on the next save. F304 found two such fields
// on `MeetingRecord` and closed the class with a `Mirror`-derived test — but that test reflects
// `MeetingRecord`'s own top level only. Four more persisted types hand-write their coding:
//
//   - `ActionItem` (inside `meetings.json` summaries): `private enum CodingKeys`, synthesized encode.
//   - `DictationLogEntry` (`dictation-log.json`): CodingKeys plus a hand-written `encode(to:)`.
//   - `SpeakerTurn` (`diarization.json`): CodingKeys with the remap `rawKind` → `kind`.
//   - `SourceTrackManifest` (`source-tracks*.json`): hand-written `encode(to:)`; its nested
//     `Track` has hand-written CodingKeys (F558), and `PaddedGap` is synthesized.
//
// The helper here derives the property list from `Mirror` instead of restating it, and walks into
// nested structs and arrays of structs, so `Track` and `PaddedGap` are covered through the
// manifest rather than by a second hand-kept list. `MeetingRecordWireFormatTests.swift` keeps its
// own top-level check (F304); this file does not replace it.

/// What `storedPropertiesMissingFromWire` found.
struct WireCoverage {
    /// Dotted paths of stored properties whose key is present in the encoded JSON.
    var checked: [String] = []
    /// Dotted paths of stored properties whose key is absent — each one is lost on the next save.
    var missing: [String] = []
    /// The remaps that matched a stored property, so a stale remap entry can be caught.
    var usedRemaps: Set<String> = []
}

/// Encodes `value` with `JSONEncoder` and reports every stored property (found by `Mirror`, which
/// sees stored properties — private ones included — and never computed ones) whose key is absent
/// from the result.
///
/// Recurses into a child whose `Mirror` is a struct or class **and** whose encoded counterpart is a
/// JSON object, and into arrays element by element. The object check is what keeps it from
/// descending into `Date`, `UUID` or `String`, which reflect as structs but encode as scalars.
/// Enums are not descended into: their payload is not a set of named stored fields.
///
/// `remapped` maps a property name to its on-disk key, at any depth. A nil optional is omitted by
/// `JSONEncoder` and so reports as missing — which is the point: the fixture must set every field,
/// or a field it never set would look identical to one that is never written.
func storedPropertiesMissingFromWire<T: Encodable>(
    _ value: T,
    remapped: [String: String] = [:]
) throws -> WireCoverage {
    let data = try JSONEncoder().encode(value)
    let encoded = try JSONSerialization.jsonObject(with: data)
    var coverage = WireCoverage()
    walkWire(value, encoded: encoded, path: "", remapped: remapped, into: &coverage)
    return coverage
}

private func walkWire(
    _ value: Any,
    encoded: Any,
    path: String,
    remapped: [String: String],
    into coverage: inout WireCoverage
) {
    let mirror = Mirror(reflecting: value)
    switch mirror.displayStyle {
    case .optional:
        if let wrapped = mirror.children.first {
            walkWire(wrapped.value, encoded: encoded, path: path, remapped: remapped, into: &coverage)
        }
    case .struct, .class:
        guard let object = encoded as? [String: Any] else { return }
        for child in mirror.children {
            guard let label = child.label else { continue }
            let key = remapped[label] ?? label
            if remapped[label] != nil { coverage.usedRemaps.insert(label) }
            let childPath = path.isEmpty ? label : "\(path).\(label)"
            if let encodedChild = object[key] {
                coverage.checked.append(childPath)
                walkWire(child.value, encoded: encodedChild, path: childPath, remapped: remapped, into: &coverage)
            } else {
                coverage.missing.append(childPath)
            }
        }
    case .collection:
        guard let array = encoded as? [Any], array.count == mirror.children.count else { return }
        for (index, (element, encodedElement)) in zip(mirror.children, array).enumerated() {
            walkWire(element.value, encoded: encodedElement, path: "\(path)[\(index)]", remapped: remapped, into: &coverage)
        }
    default:
        return
    }
}

struct PersistedWireFormatTests {
    /// Asserts nothing is missing, that the walk actually visited the paths named in `mustCheck`
    /// (the anti-vacuity half: a helper that reflected nothing would report nothing missing), and
    /// that every remap still names a real property.
    private func expectEveryStoredFieldEncoded<T: Encodable>(
        _ value: T,
        remapped: [String: String] = [:],
        mustCheck: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let coverage = try storedPropertiesMissingFromWire(value, remapped: remapped)
        #expect(
            !coverage.checked.isEmpty,
            "Mirror found no stored properties on \(T.self), so this test would pass vacuously",
            sourceLocation: sourceLocation
        )
        let unvisited = mustCheck.filter { !coverage.checked.contains($0) }
        #expect(
            unvisited.isEmpty,
            "the walk never reached \(unvisited.joined(separator: ", ")) on \(T.self)",
            sourceLocation: sourceLocation
        )
        let staleRemaps = Set(remapped.keys).subtracting(coverage.usedRemaps)
        #expect(
            staleRemaps.isEmpty,
            "remap entries name no stored property of \(T.self): \(staleRemaps.sorted().joined(separator: ", "))",
            sourceLocation: sourceLocation
        )
        #expect(
            coverage.missing.isEmpty,
            "these stored fields of \(T.self) never reach disk, so they are lost on the next save: \(coverage.missing.sorted().joined(separator: ", "))",
            sourceLocation: sourceLocation
        )
    }

    @Test("The wire helper names a stored field a hand-written CodingKeys leaves out (F544)")
    func helperReportsAnOmittedField() throws {
        // The helper's own red case, kept permanently so it cannot rot into a check that passes
        // everything: `dropped` is stored, set, and absent from CodingKeys, exactly the F304 shape.
        struct Probe: Codable {
            var kept: String = "k"
            var dropped: String? = "d"
            var nested: Inner = Inner()
            struct Inner: Codable {
                var shown: Int = 1
                var hidden: Int? = 2
                private enum CodingKeys: String, CodingKey { case shown }
            }
            private enum CodingKeys: String, CodingKey { case kept, nested }
        }
        let coverage = try storedPropertiesMissingFromWire(Probe())
        #expect(coverage.missing.sorted() == ["dropped", "nested.hidden"])
        #expect(coverage.checked.contains("nested.shown"))
    }

    @Test("Every stored field of an ActionItem reaches the wire format (F544)")
    func actionItemEncodesEveryStoredField() throws {
        let item = ActionItem(
            text: "Email the vendor",
            done: true,
            owner: "Ana",
            due: "Fri",
            quote: "I'll email them today",
            timestamp: 12.5
        )
        try expectEveryStoredFieldEncoded(
            item,
            mustCheck: ["text", "done", "owner", "due", "quote", "timestamp"]
        )
    }

    @Test("Every stored field of a DictationLogEntry reaches the wire format (F544)")
    func dictationLogEntryEncodesEveryStoredField() throws {
        // `outcomeKind` is set explicitly: it is nil for every case this build knows, so a fixture
        // built from an ordinary outcome would never exercise it.
        let entry = DictationLogEntry(
            id: UUID(),
            date: Date(timeIntervalSince1970: 1_700_000_000),
            text: "hello",
            outcome: .failed("x"),
            rawText: "helo",
            refinement: DictationRefinement.refined.rawValue,
            outcomeKind: "discarded"
        )
        try expectEveryStoredFieldEncoded(
            entry,
            mustCheck: ["id", "date", "text", "outcome", "rawText", "refinement", "outcomeKind"]
        )
    }

    @Test("Every stored field of a SpeakerTurn reaches the wire format (F544)")
    func speakerTurnEncodesEveryStoredField() throws {
        // The documented remap: the stored property is `rawKind`, the on-disk key is `kind`.
        let turn = SpeakerTurn(startSeconds: 1, endSeconds: 2, clusterID: 3, kind: .overlap)
        try expectEveryStoredFieldEncoded(
            turn,
            remapped: ["rawKind": "kind"],
            mustCheck: ["startSeconds", "endSeconds", "clusterID", "rawKind"]
        )
    }

    @Test("Every stored field of a SourceTrackManifest, its Tracks and gaps reaches the wire (F544)")
    func sourceTrackManifestEncodesEveryStoredField() throws {
        // `paddedGaps` and `supersededRecordings` are omitted when empty by design, and
        // `droppedFrameCount` / `truncatedAtSeconds` when nil, so every one is populated here.
        func track(_ file: String, dropped: Int64) -> SourceTrackManifest.Track {
            SourceTrackManifest.Track(
                file: file,
                format: "float32",
                sampleRate: 48_000,
                channels: 1,
                frameCount: 480_000,
                startOffsetSeconds: 0.25,
                droppedFrameCount: dropped
            )
        }
        let manifest = SourceTrackManifest(
            recoveryAlignment: SourceTrackManifest.rebuiltPaddedAlignment,
            paddedGaps: [SourceTrackManifest.PaddedGap(startSeconds: 3, durationSeconds: 1.5)],
            supersededRecordings: ["meeting.superseded-1.wav"],
            truncatedAtSeconds: 9,
            systemAudio: track("system-audio.f32", dropped: 5),
            microphoneAudio: track("microphone-audio.f32", dropped: 7)
        )
        try expectEveryStoredFieldEncoded(
            manifest,
            mustCheck: [
                "recoveryAlignment", "paddedGaps", "supersededRecordings", "truncatedAtSeconds",
                "systemAudio", "microphoneAudio",
                "paddedGaps[0].startSeconds", "paddedGaps[0].durationSeconds",
                "systemAudio.startOffsetSeconds", "systemAudio.droppedFrameCount",
                "microphoneAudio.file", "microphoneAudio.droppedFrameCount",
            ]
        )
    }

    @Test("Every Sources file with hand-written coding is covered by a wire check or is decode-only (F544)")
    func everyHandWrittenCodingFileIsAccountedFor() throws {
        // Derives the set of files that hand-write `CodingKeys` or `encode(to:)` rather than trusting
        // the four types above to be all of them, so a fifth persisted type with hand-written coding
        // fails here until somebody decides how its fields are guarded. Per-file, not per-type: a new
        // type with hand-written coding in an already-listed file is not caught.
        let accountedFor: [String: String] = [
            "Sources/WhisperCore/MeetingSummarizer.swift": "ActionItem — actionItemEncodesEveryStoredField",
            "Sources/WhisperCore/DictationLog.swift": "DictationLogEntry — dictationLogEntryEncodesEveryStoredField",
            "Sources/WhisperCore/SpeakerTurn.swift": "SpeakerTurn — speakerTurnEncodesEveryStoredField",
            "Sources/WhisperCore/SourceTrackManifest.swift": "SourceTrackManifest — sourceTrackManifestEncodesEveryStoredField",
            "Sources/WhisperMeet/MeetingStore.swift": "MeetingRecord — everyStoredFieldIsEncoded (F304); SchemaMarker is a single value",
            "Sources/WhisperCore/LocalWhisperClient.swift": "WhisperSegment — Decodable-only subprocess parser",
            "Sources/WhisperCore/MediaDownloadClient.swift": "YtDlpProbeOutput — Decodable-only subprocess parser",
        ]
        let root = SourceAssertion.repositoryRoot.standardizedFileURL.path + "/"
        var found: Set<String> = []
        for directory in ["Sources/WhisperCore", "Sources/WhisperMeet"] {
            for url in try SourceAssertion.swiftFileURLs(under: directory) {
                let code = SourceAssertion.stripComments(try String(contentsOf: url, encoding: .utf8))
                guard code.contains("enum CodingKeys") || code.contains("func encode(to") else { continue }
                let path = url.standardizedFileURL.path
                found.insert(path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path)
            }
        }
        #expect(found.count >= 4, "the scan found almost nothing, so this test would pass vacuously")
        let unaccounted = found.subtracting(accountedFor.keys)
        #expect(
            unaccounted.isEmpty,
            "hand-written coding with no wire check — add one to this file or list it as decode-only: \(unaccounted.sorted().joined(separator: ", "))"
        )
        let stale = Set(accountedFor.keys).subtracting(found)
        #expect(
            stale.isEmpty,
            "listed but no longer hand-writing coding, so the entry is stale: \(stale.sorted().joined(separator: ", "))"
        )
    }
}
