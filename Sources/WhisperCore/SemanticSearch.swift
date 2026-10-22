import CryptoKit
import Foundation

/// One meeting's segment embeddings, kept beside its recording (F316).
///
/// Advisory, like `notes.md`: delete the two files and the meeting is simply searched by keyword
/// until the index is rebuilt. They hold vectors, not text.
public struct SegmentEmbeddings: Sendable, Equatable {
    public static let metadataFilename = "ask-embeddings.json"
    public static let vectorsFilename = "ask-embeddings.f32"

    public let modelID: String
    /// Of the texts the vectors were computed from: a meeting's segments, or a hand-edited
    /// transcript's lines (`EditedTranscript`, F455). A re-transcription or an edit changes it.
    public let fingerprint: String
    public let dimension: Int
    /// `count × dimension`, row-major, L2-normalised by the embedder.
    public let vectors: [Float]

    public var count: Int { dimension > 0 ? vectors.count / dimension : 0 }

    public init(modelID: String, fingerprint: String, dimension: Int, vectors: [Float]) {
        self.modelID = modelID
        self.fingerprint = fingerprint
        self.dimension = dimension
        self.vectors = vectors
    }

    public static func fingerprint(of texts: [String]) -> String {
        var hasher = SHA256()
        for text in texts {
            hasher.update(data: Data(text.utf8))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `Float`s out of file bytes without assuming the bytes are 4-byte aligned (F333).
    ///
    /// `Data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }` reads aligned loads off a
    /// pointer `Data` does not promise to align — it happens to hold for a whole-file read and not
    /// for every slice. A copy is the same cost as the `Array` this replaces.
    static func floats(from data: Data, count: Int) -> [Float] {
        var values = [Float](repeating: 0, count: count)
        _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return values
    }

    /// The byte length of `count × dimension` float32 values, or nil when either multiplication
    /// overflows `Int`, the count is negative, or the dimension is not positive (F462; the last is
    /// the `dimension > 0` both callers already checked).
    ///
    /// Both numbers come from a JSON file — `ask-embeddings.json`, or the helper's own answer in
    /// `LocalEmbedder.embed` — so a damaged or foreign one can carry a dimension like 2^62 that is
    /// positive, decodes cleanly, and made the bare `count * dimension * 4` trap: the size check that
    /// exists to turn a bad file into "no index" crashed the app instead. Shared, so the two checks
    /// cannot drift apart.
    static func vectorByteCount(count: Int, dimension: Int) -> Int? {
        guard count >= 0, dimension > 0 else { return nil }
        let (values, valuesOverflowed) = count.multipliedReportingOverflow(by: dimension)
        let (bytes, bytesOverflowed) = values.multipliedReportingOverflow(by: MemoryLayout<Float>.size)
        guard !valuesOverflowed, !bytesOverflowed else { return nil }
        return bytes
    }

    private struct Metadata: Codable {
        let modelID: String
        let fingerprint: String
        let dimension: Int
        let count: Int
    }

    public func write(to directory: URL) throws {
        // The OLD metadata goes first, before the new vectors land (F333): between the two writes it
        // would otherwise sit beside vectors it does not describe, and "metadata last" only makes
        // the *presence* of metadata meaningful, not its agreement with what is beside it. Removing
        // it first makes that window read as "no index" — a rebuild, which is what every other
        // disagreement here costs.
        let metadataURL = directory.appendingPathComponent(Self.metadataFilename)
        try? FileManager.default.removeItem(at: metadataURL)
        let data = vectors.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: directory.appendingPathComponent(Self.vectorsFilename), options: .atomic)
        // Metadata last: its presence is what says the vectors beside it are whole.
        let metadata = Metadata(modelID: modelID, fingerprint: fingerprint, dimension: dimension, count: count)
        try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
    }

    /// The index for exactly these texts and this model, or nil — stale, foreign and truncated
    /// indexes are all "no index", which costs a rebuild and never a wrong answer.
    public static func read(from directory: URL, modelID: String, texts: [String]) -> SegmentEmbeddings? {
        guard let raw = try? Data(contentsOf: directory.appendingPathComponent(metadataFilename)),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: raw),
              metadata.modelID == modelID, metadata.count == texts.count,
              metadata.fingerprint == fingerprint(of: texts),
              let byteCount = vectorByteCount(count: metadata.count, dimension: metadata.dimension),
              let data = try? Data(contentsOf: directory.appendingPathComponent(vectorsFilename)),
              data.count == byteCount
        else { return nil }
        // `count × dimension` cannot overflow here: `byteCount`, four times it, did not.
        let vectors = Self.floats(from: data, count: metadata.count * metadata.dimension)
        return SegmentEmbeddings(modelID: modelID, fingerprint: metadata.fingerprint,
                                 dimension: metadata.dimension, vectors: vectors)
    }
}

/// Nearest passages to a question vector, as the same citations keyword search returns (F316).
public enum SemanticRanker {
    /// Below this nothing is offered.
    ///
    /// **0.70, not 0.76 (F329).** On the measured set right answers ran 0.76–0.86 and unrelated
    /// passages 0.70–0.86, so no floor separates them. 0.76 was therefore sitting exactly on the
    /// *minimum observed correct* similarity, over 20 pairs written by one author — which on unseen
    /// data drops correct passages silently, and because `RankFusion` only ever sees the survivors
    /// they cannot appear at any rank. A floor that cannot separate the two populations belongs well
    /// below the correct range, not at its edge; ordering, not the floor, is what the fusion relies
    /// on, and that argument was already written here while the value contradicted it.
    ///
    /// What it still does: drop a passage no reading calls related — a near-zero or negative cosine
    /// from an empty, garbled or wrong-language segment. What it does not do: separate right from
    /// wrong.
    ///
    /// **Measured against the committed set (F392, 2026-10-21, `floorAndFusionSweepWithTheInstalledModel`).**
    /// English questions' own passages scored 0.735–0.850 and every other passage up to 0.837; English
    /// questions over Mandarin speech 0.779–0.801 against up to 0.825. The populations overlap whole, as
    /// F329 argued, and 0.70 and 0.76 give the same recall for every language; 0.80 loses most of it
    /// (English recall@1 0.542 → 0.375, cross-language recall@5 1.000 → 0.333). So 0.70 stays.
    public static let minimumSimilarity: Float = 0.70

    public static func rank(
        query: [Float], in meetings: [(meeting: SearchableMeeting, index: SegmentEmbeddings)], limit: Int
    ) -> [CitedResult] {
        rank(query: query, in: meetings, limit: limit, floor: minimumSimilarity)
    }

    /// `rank` at another floor, for F392's sweep against the committed pair set; the app ranks at
    /// `minimumSimilarity` only.
    static func rank(
        query: [Float], in meetings: [(meeting: SearchableMeeting, index: SegmentEmbeddings)], limit: Int, floor: Float
    ) -> [CitedResult] {
        guard limit > 0, !query.isEmpty else { return [] }
        var hits: [CitedResult] = []
        for (meeting, index) in meetings where index.dimension == query.count && index.count == meeting.segments.count {
            for (row, segment) in meeting.segments.enumerated() {
                let base = row * index.dimension
                var dot: Float = 0
                for column in 0..<index.dimension { dot += query[column] * index.vectors[base + column] }
                guard dot >= floor else { continue }
                hits.append(CitedResult(
                    meetingID: meeting.id, meetingTitle: meeting.title, segmentIndex: segment.index,
                    timestamp: segment.start, snippet: segment.text, score: Double(dot)
                ))
            }
        }
        // Higher score first, ties by id — the order it always had, now found by sorting positions
        // (F1048). Sorting the results themselves moved values holding three strings each, and the
        // comparator built two UUID-string ids per comparison whether or not the scores tied; nearly
        // every row clears the floor, so that was most of a query: in a release build at 20,000 rows,
        // ranking took 84–88 ms (about 4 µs a row), of which the dot products were under 4 ms; it now
        // takes 6 ms when the scores differ, as real embeddings' do.
        let order = hits.indices.sorted { a, b in
            hits[a].score != hits[b].score ? hits[a].score > hits[b].score : hits[a].id < hits[b].id
        }
        return order.prefix(limit).map { hits[$0] }
    }
}

/// Reciprocal rank fusion of the keyword and meaning rankings (F316).
///
/// RRF uses ranks, not scores, so it needs neither BM25 and cosine put on one scale — the standard way
/// to combine a lexical and a dense retriever. A passage scores the sum of 1/(k + rank) over the lists
/// that hold it.
///
/// **`k = 1`, not the paper's 60 (F1065, from F392's measurement).** 60 is the constant for lists a
/// thousand deep. Both lists here are capped at 20, and at 60 the best single-list score was 1/61 while
/// any passage in both lists scored at least 2/80, so a passage both searches put last outranked a
/// perfect paraphrase only one found (F330). F392 measured what that cost against the committed set
/// (`floorAndFusionSweepWithTheInstalledModel`): English questions over Mandarin speech, which only
/// meaning can answer, reached the top five 2 of 6 times fused against 6 of 6 by meaning, at every `k`
/// from 5 to 60. At `k = 1` a first place in either list scores 1/2 and last in both 2/21, so rank
/// matters again while agreement near the top still wins (second in both, 2/3, beats first in one).
/// Measured at the shipped floor: cross-language recall@5 0.333 → 0.833 and recall@3 0.167 → 0.500;
/// English recall@5 0.625 → 0.667 with recall@1 and @3 unchanged; Mandarin unchanged (recall@3 1.000);
/// and the exact-term questions keyword search is for, added for F1065, at 1.000 for every `k`. The
/// same protection holds for keyword: a first-place exact match meaning cannot see is no longer
/// outranked by passages both lists returned.
///
/// Among passages one list holds, scores at equal rank are bit-identical, so the insertion-order
/// tie-break fires and `lexical` is enumerated first — the fused tail alternates L1, S1, L2, S2, … with
/// keyword taking the earlier slot, at any `k` (`fusionBreaksExactTiesTowardKeyword`).
public enum RankFusion {
    static let k = 1.0

    public static func fuse(lexical: [CitedResult], semantic: [CitedResult], limit: Int) -> [CitedResult] {
        fuse(lexical: lexical, semantic: semantic, limit: limit, k: k)
    }

    /// `fuse` with another constant, for F392's sweep against the committed pair set; the app fuses
    /// with `k` only.
    static func fuse(lexical: [CitedResult], semantic: [CitedResult], limit: Int, k: Double) -> [CitedResult] {
        // `prefix` traps on a negative count, and the sibling rankers already guard it (F333).
        guard limit > 0 else { return [] }
        guard !semantic.isEmpty else { return Array(lexical.prefix(limit)) }
        var scores: [String: Double] = [:]
        var first: [String: (order: Int, result: CitedResult)] = [:]
        var order = 0
        for list in [lexical, semantic] {
            for (rank, result) in list.enumerated() {
                scores[result.id, default: 0] += 1 / (k + Double(rank + 1))
                if first[result.id] == nil { first[result.id] = (order, result); order += 1 }
            }
        }
        return first.values
            .sorted { (scores[$0.result.id] ?? 0, $1.order) > (scores[$1.result.id] ?? 0, $0.order) }
            .prefix(limit)
            .map { entry in
                CitedResult(
                    meetingID: entry.result.meetingID, meetingTitle: entry.result.meetingTitle,
                    segmentIndex: entry.result.segmentIndex, timestamp: entry.result.timestamp,
                    snippet: entry.result.snippet, score: scores[entry.result.id] ?? 0
                )
            }
    }
}
