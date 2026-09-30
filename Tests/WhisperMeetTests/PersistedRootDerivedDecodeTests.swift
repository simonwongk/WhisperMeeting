import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F382 — the decode-side half of the persisted-root guard, derived from the types rather than
// written by hand.
//
// `PersistedRootSurvivalTests.swift` is hand-written fixtures, and a hand-written fixture only
// exercises the keys it names. A new OPTIONAL enum field with a synthesized (throwing) decode is
// absent from every one of them, so `decodeIfPresent` returns nil without entering the enum's
// decoder and that suite stays green — while a newer build's value in that field makes the whole
// root unreadable on a user's disk. That is the 2026-08-14 shape, and `MeetingSummary.tone: Tone?`
// is the example F382 names.
//
// A key that IS present with an unmatched value throws, so the repair is to make every key present
// and then feed each one a value no build has written:
//
//   1. A fully populated fixture per root, and `storedPropertiesMissingFromWire` (F544's `Mirror`
//      walk, `PersistedWireFormatTests.swift`) asserting it sets every stored property, walking
//      into nested structs and arrays. An optional field added to a persisted type and left nil
//      here fails that check first — so the fixture cannot quietly omit the key the substitution
//      below needs.
//   2. Encode the fixture as `BackupJSONStore` does, and replace ONE leaf at a time with an unknown
//      value — a string leaf with `"valueFromTheFuture"`, a number leaf with `987654321` — then
//      decode the whole root. Any throw is reported with the leaf's path. A present string value
//      always enters a `String`-backed enum's decoder, and a number value an `Int`-backed one.
//
// Never substitute JSON `null`: it returns nil without entering the decoder, so it would look like
// coverage and exercise nothing (`PersistedRootSurvivalTests`' header notes the same).
//
// Deliberately skipped, because they are strict for a reason and are not enums: strings that parse
// as a UUID or an ISO-8601 date (ids and timestamps), and booleans.
//
// Not covered: an enum encoded as an OBJECT — a synthesized associated-value enum, such as
// `DictationLogEntry.Outcome` (`{"pasted":{}}`) — whose unknown case is an unknown KEY, not an
// unknown leaf. Outcome's own leniency is pinned in `DictationLogSchemaTests`.
//
// The set of roots is not restated either: `everyPersistedRootIsCovered` scans Sources for
// `BackupJSONStore<…>` and compares it with `coveredRoots`, so a fifth root fails until it has a
// fixture here.

/// What `decodeFailuresUnderUnknownValues` did.
struct UnknownValueReport {
    /// Paths of every leaf that was replaced, in visit order.
    var substituted: [String] = []
    /// Path of each leaf whose unknown value made the whole root fail to decode, with the error.
    var failures: [String: String] = [:]
}

private enum JSONPathStep {
    case key(String)
    case index(Int)
}

private let unknownStringValue = "valueFromTheFuture"
private let unknownNumberValue = 987_654_321

/// Encodes `value` with the coder settings `BackupJSONStore` uses (ISO-8601 dates), then for each
/// string or number leaf in turn replaces that one leaf with an unknown value and decodes `T` from
/// the result. See the file header for what is skipped and why.
func decodeFailuresUnderUnknownValues<T: Codable>(_ value: T) throws -> UnknownValueReport {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let tree = try JSONSerialization.jsonObject(
        with: try encoder.encode(value), options: [.fragmentsAllowed]
    )
    var leaves: [(path: [JSONPathStep], replacement: Any)] = []
    collectLeaves(tree, path: [], into: &leaves)

    var report = UnknownValueReport()
    for leaf in leaves {
        let name = describe(leaf.path)
        report.substituted.append(name)
        let mutated = replacing(in: tree, at: leaf.path[...], with: leaf.replacement)
        let data = try JSONSerialization.data(withJSONObject: mutated, options: [.fragmentsAllowed])
        do {
            _ = try decoder.decode(T.self, from: data)
        } catch {
            report.failures[name] = describe(error)
        }
    }
    return report
}

private func collectLeaves(
    _ node: Any,
    path: [JSONPathStep],
    into leaves: inout [(path: [JSONPathStep], replacement: Any)]
) {
    if let object = node as? [String: Any] {
        for key in object.keys.sorted() {
            collectLeaves(object[key]!, path: path + [.key(key)], into: &leaves)
        }
    } else if let array = node as? [Any] {
        for (index, element) in array.enumerated() {
            collectLeaves(element, path: path + [.index(index)], into: &leaves)
        }
    } else if let string = node as? String {
        let isStrictFormat = UUID(uuidString: string) != nil
            || ISO8601DateFormatter().date(from: string) != nil
        if !isStrictFormat {
            leaves.append((path, unknownStringValue))
        }
    } else if let number = node as? NSNumber {
        // JSONSerialization hands back booleans as NSNumber too; a Bool cannot be an enum.
        if CFGetTypeID(number) != CFBooleanGetTypeID() {
            leaves.append((path, NSNumber(value: unknownNumberValue)))
        }
    }
    // NSNull: nothing to substitute (and substituting null would exercise nothing).
}

private func replacing(in node: Any, at path: ArraySlice<JSONPathStep>, with replacement: Any) -> Any {
    guard let step = path.first else { return replacement }
    let rest = path.dropFirst()
    switch step {
    case .key(let key):
        guard var object = node as? [String: Any], let child = object[key] else { return node }
        object[key] = replacing(in: child, at: rest, with: replacement)
        return object
    case .index(let index):
        guard var array = node as? [Any], array.indices.contains(index) else { return node }
        array[index] = replacing(in: array[index], at: rest, with: replacement)
        return array
    }
}

private func describe(_ path: [JSONPathStep]) -> String {
    var text = ""
    for step in path {
        switch step {
        case .key(let key): text += text.isEmpty ? key : ".\(key)"
        case .index(let index): text += "[\(index)]"
        }
    }
    return text.isEmpty ? "(root)" : text
}

private func describe(_ error: Error) -> String {
    let context: DecodingError.Context?
    switch error as? DecodingError {
    case .dataCorrupted(let c)?: context = c
    case .keyNotFound(_, let c)?: context = c
    case .typeMismatch(_, let c)?: context = c
    case .valueNotFound(_, let c)?: context = c
    default: context = nil
    }
    guard let context else { return String(describing: error) }
    let path = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
    return "\(path): \(context.debugDescription)"
}

struct PersistedRootDerivedDecodeTests {
    /// The four roots this file has a fixture for, spelled as their `BackupJSONStore<…>` argument.
    /// `everyPersistedRootIsCovered` holds this against Sources.
    static let coveredRoots: Set<String> = ["[MeetingRecord]", "[String]", "[ReplacementRule]", "DictationLog"]

    /// Asserts the substitution pass visited `mustTry` (so it cannot pass by visiting nothing) and
    /// that no unknown value made the root unreadable.
    private func expectEveryLeafTolerated<T: Codable>(
        _ value: T,
        mustTry: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let report = try decodeFailuresUnderUnknownValues(value)
        let untried = mustTry.filter { !report.substituted.contains($0) }
        #expect(
            untried.isEmpty,
            "the substitution never reached \(untried.joined(separator: ", ")) in \(T.self)",
            sourceLocation: sourceLocation
        )
        #expect(
            report.failures.isEmpty,
            "an unknown value here makes the whole \(T.self) unreadable: \(report.failures.sorted { $0.key < $1.key }.map { "\($0.key) — \($0.value)" }.joined(separator: "; "))",
            sourceLocation: sourceLocation
        )
    }

    /// Asserts the fixture sets every stored property at every depth, so no key is absent from the
    /// encoded root for the substitution pass to miss.
    private func expectFixtureComplete<T: Encodable>(
        _ value: T,
        remapped: [String: String] = [:],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let coverage = try storedPropertiesMissingFromWire(value, remapped: remapped)
        #expect(!coverage.checked.isEmpty, "Mirror found nothing in \(T.self)", sourceLocation: sourceLocation)
        #expect(
            coverage.missing.isEmpty,
            "the fixture leaves these unset, so an unknown value there is never tried — set them: \(coverage.missing.sorted().joined(separator: ", "))",
            sourceLocation: sourceLocation
        )
    }

    @Test("The substitution helper names a strict optional enum a hand-written fixture would omit (F382)")
    func helperNamesAStrictOptionalEnum() throws {
        // The helper's own red case, kept permanently so it cannot rot into a check that passes
        // everything. `tone` is exactly F382's shape: optional, String-backed, synthesized decode.
        struct Probe: Codable {
            enum Tone: String, Codable { case formal }
            enum Level: Int, Codable { case one = 1 }
            struct Item: Codable {
                var level: Level? = .one
                var note: String? = "n"
            }
            var title: String = "t"
            var tone: Tone? = .formal
            var items: [Item] = [Item()]
            var id: UUID = UUID()
            var flag: Bool = true
        }
        let report = try decodeFailuresUnderUnknownValues(Probe())
        #expect(report.failures.keys.sorted() == ["items[0].level", "tone"])
        #expect(report.substituted.contains("title"))
        #expect(report.substituted.contains("items[0].note"))
        #expect(!report.substituted.contains("id"), "a UUID is strict by design and must be skipped")
        #expect(!report.substituted.contains("flag"), "a Bool cannot be an enum")
    }

    @Test("Every leaf of a fully populated meeting index tolerates a value from a newer build (F382)")
    func meetingIndexToleratesUnknownValues() throws {
        let records = [Self.fullyPopulatedMeeting()]
        try expectFixtureComplete(
            records,
            remapped: ["transcriptionEngineRawValue": "transcriptionEngine", "schemaMarker": "schemaVersion"]
        )
        try expectEveryLeafTolerated(
            records,
            mustTry: [
                "[0].status", "[0].transcriptionEngine", "[0].requestedLanguage", "[0].schemaVersion",
                "[0].recoverySource", "[0].recoveryInterruption", "[0].source.kind",
                "[0].healthReport.worstStatus", "[0].healthReport.warnings[0]",
                "[0].summary.actionItems[0].owner", "[0].segments[0].speaker",
            ]
        )
    }

    @Test("Every leaf of a fully populated dictation log tolerates a value from a newer build (F382)")
    func dictationLogToleratesUnknownValues() throws {
        let log = DictationLog(entries: [Self.fullyPopulatedDictationEntry()], limit: 100)
        try expectFixtureComplete(log)
        try expectEveryLeafTolerated(
            log,
            mustTry: ["entries[0].refinement", "entries[0].outcomeKind", "entries[0].outcome.failed._0", "limit"]
        )
    }

    @Test("Every leaf of the replacement rules and the vocabulary tolerates a value from a newer build (F382)")
    func rulesAndVocabularyTolerateUnknownValues() throws {
        let rules = [ReplacementRule(heard: "kestrelle", preferred: "Kestrel")]
        try expectFixtureComplete(rules)
        try expectEveryLeafTolerated(rules, mustTry: ["[0].heard", "[0].preferred"])
        // `[String]` has no stored properties to walk, so only the substitution applies.
        try expectEveryLeafTolerated(["Kestrel"], mustTry: ["[0]"])
    }

    @Test("Every BackupJSONStore root in Sources has a derived fixture here (F382)")
    func everyPersistedRootIsCovered() throws {
        // Derives the roots instead of trusting the list in `PersistedRootSurvivalTests`' header:
        // every `BackupJSONStore<T>` spelled in comment-stripped Sources, other than a nested-type
        // reference (`BackupJSONStore<T>.StoreRepair`) and the generic's own declaration file.
        //
        // Blind spot, named: a store whose type is only ever inferred (`let s = BackupJSONStore(…)`
        // with no annotation anywhere) spells no `<T>`. The construction count below is the second
        // check with a different blind spot: each covered root is constructed exactly once today.
        var found: Set<String> = []
        var constructions = 0
        for directory in ["Sources/WhisperCore", "Sources/WhisperMeet"] {
            for url in try SourceAssertion.swiftFileURLs(under: directory)
            where url.lastPathComponent != "BackupJSONStore.swift" {
                let code = SourceAssertion.stripComments(try String(contentsOf: url, encoding: .utf8))
                found.formUnion(Self.backupStoreTypeArguments(in: code))
                constructions += code.components(separatedBy: "BackupJSONStore(").count - 1
            }
        }
        #expect(found.count >= 2, "the scan found almost nothing, so this test would pass vacuously")
        #expect(
            found == Self.coveredRoots,
            "persisted roots without a derived fixture: \(found.subtracting(Self.coveredRoots).sorted()); covered but no longer in Sources: \(Self.coveredRoots.subtracting(found).sorted())"
        )
        #expect(
            constructions == Self.coveredRoots.count,
            "\(constructions) BackupJSONStore constructions for \(Self.coveredRoots.count) covered roots — a new store needs a fixture here"
        )
    }

    /// The type argument of every `BackupJSONStore<…>` in `code` that is not followed by `.`,
    /// with nested angle brackets balanced.
    static func backupStoreTypeArguments(in code: String) -> Set<String> {
        var result: Set<String> = []
        var remainder = code[...]
        let marker = "BackupJSONStore<"
        while let start = remainder.range(of: marker) {
            var depth = 1
            var index = start.upperBound
            while index < remainder.endIndex, depth > 0 {
                switch remainder[index] {
                case "<": depth += 1
                case ">": depth -= 1
                default: break
                }
                index = remainder.index(after: index)
            }
            guard depth == 0 else { break }
            let argument = String(remainder[start.upperBound..<remainder.index(before: index)])
            let followedByMember = index < remainder.endIndex && remainder[index] == "."
            if !followedByMember { result.insert(argument.replacingOccurrences(of: " ", with: "")) }
            remainder = remainder[index...]
        }
        return result
    }

    /// Every stored property set, nested ones included — `expectFixtureComplete` is what says so
    /// when a field is added. Local rather than shared with `MeetingRecordWireFormatTests`' builder, which
    /// is private to that file.
    static func fullyPopulatedMeeting() -> MeetingRecord {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let segment = TranscriptSegment(
            speaker: "Speaker 1", start: 0, end: 1, text: "hello",
            avgLogprob: -0.2, noSpeechProb: 0.01, compressionRatio: 1.4
        )
        return MeetingRecord(
            id: UUID(),
            title: "Quarterly review",
            createdAt: date,
            duration: 1234.5,
            recordingPath: "Recordings/x/meeting.wav",
            status: .completed,
            transcriptText: "hello",
            languageCode: "en",
            confidence: 0.92,
            segments: [segment],
            errorMessage: "an error",
            summary: MeetingSummary(
                summary: "s",
                keyPoints: ["k"],
                actionItems: [ActionItem(text: "a", done: false, owner: "Ana", due: "Fri", quote: "q", timestamp: 3)]
            ),
            transcriptNormalized: true,
            markers: [RecordingMarker(offset: 5, label: "here")],
            pinned: true,
            notes: "notes",
            tags: ["tag"],
            healthReport: RecordingHealthReport(
                warnings: [.microphoneClipping],
                worstStatus: .caution,
                microphoneStaleSeconds: 0,
                systemAudioStaleSeconds: 0,
                systemAudioEverDetected: true,
                microphoneFramesMeasured: 10,
                microphoneFramesAtFullScale: 1,
                systemAudioFramesMeasured: 10,
                systemAudioFramesAtFullScale: 2,
                microphoneWorstSecond: ClippedSecond(framesMeasured: 4, framesAtFullScale: 1),
                systemAudioWorstSecond: ClippedSecond(framesMeasured: 4, framesAtFullScale: 2)
            ),
            alignmentWarning: "alignment",
            recoveryWarning: "recovery",
            recoverySource: RecoveredRecording.Source.rebuiltSourceTracks.rawValue,
            staleTranscriptWarning: "stale",
            recoveryInterruption: RecoveryInterruption.systemSleep.rawValue,
            languageWarning: "language",
            summaryLanguageWarning: "summary language",
            repeatsRemoved: 15,
            transcriptionEngine: .qwenBalanced,
            requestedLanguage: WhisperLanguage.chinese.rawValue,
            source: MediaSource(
                kind: MediaSource.youTubeKind,
                pageURL: "https://example.com/a",
                host: "example.com",
                videoID: "abc123",
                uploader: "Uploader",
                uploadDate: date,
                fetchedAt: date
            ),
            referenceSegments: [segment]
        )
    }

    static func fullyPopulatedDictationEntry() -> DictationLogEntry {
        // `outcomeKind` is set explicitly: it is nil for every case this build knows.
        DictationLogEntry(
            id: UUID(),
            date: Date(timeIntervalSince1970: 1_700_000_000),
            text: "hello",
            outcome: .failed("x"),
            rawText: "helo",
            refinement: DictationRefinement.refined.rawValue,
            outcomeKind: "discarded"
        )
    }
}
