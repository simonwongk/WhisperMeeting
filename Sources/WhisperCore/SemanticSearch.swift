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
    /// Of the segment texts the vectors were computed from; a re-transcription or an edit changes it.
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
              metadata.modelID == modelID, metadata.count == texts.count, metadata.dimension > 0,
              metadata.fingerprint == fingerprint(of: texts),
              let data = try? Data(contentsOf: directory.appendingPathComponent(vectorsFilename)),
              data.count == metadata.count * metadata.dimension * MemoryLayout<Float>.size
        else { return nil }
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
    /// wrong. The pair set that produced those ranges is not committed, so neither value can be
    /// re-derived here; that is F350.
    public static let minimumSimilarity: Float = 0.70

    public static func rank(
        query: [Float], in meetings: [(meeting: SearchableMeeting, index: SegmentEmbeddings)], limit: Int
    ) -> [CitedResult] {
        guard limit > 0, !query.isEmpty else { return [] }
        var hits: [CitedResult] = []
        for (meeting, index) in meetings where index.dimension == query.count && index.count == meeting.segments.count {
            for (row, segment) in meeting.segments.enumerated() {
                let base = row * index.dimension
                var dot: Float = 0
                for column in 0..<index.dimension { dot += query[column] * index.vectors[base + column] }
                guard dot >= minimumSimilarity else { continue }
                hits.append(CitedResult(
                    meetingID: meeting.id, meetingTitle: meeting.title, segmentIndex: segment.index,
                    timestamp: segment.start, snippet: segment.text, score: Double(dot)
                ))
            }
        }
        return Array(hits.sorted { ($0.score, $1.id) > ($1.score, $0.id) }.prefix(limit))
    }
}

/// Reciprocal rank fusion of the keyword and meaning rankings (F316).
///
/// RRF uses ranks, not scores, so it needs neither BM25 and cosine put on one scale nor any tuning —
/// the standard way to combine a lexical and a dense retriever. `k = 60` is the constant from the
/// original paper and what every implementation ships.
///
/// **"Tuning-free" is not true at this scale, and the constant decides the outcome (F330).** Both
/// lists are capped at 20, so the best single-list score is 1/61 = 0.01639 and the worst is
/// 1/80 = 0.01250, while *any* document present in both lists scores at least 2/80 = 0.02500. Every
/// co-occurring passage therefore outranks every single-list passage regardless of rank: a mediocre
/// passage at rank 20 in both beats a perfect paraphrase at semantic rank 1. And among single-list
/// passages the scores at equal rank are bit-identical, so the insertion-order tie-break fires on
/// all of them and `lexical` is enumerated first — the fused tail is a strict L1, S1, L2, S2, …
/// alternation with keyword always taking the earlier slot.
///
/// For F182 that means `answerPassageLimit = 5` shows the answer model at most two meaning-only
/// passages whenever BM25 returns anything. `fusionRanksCoOccurrenceAboveEveryone` and
/// `fusionBreaksExactTiesTowardKeyword` pin both effects, so the behaviour is observed rather than
/// assumed — but whether `k = 60` is the right constant for 20-deep lists is unmeasured, and
/// measuring it needs the pair set F350 asks for. Do not change it blind.
public enum RankFusion {
    static let k = 60.0

    public static func fuse(lexical: [CitedResult], semantic: [CitedResult], limit: Int) -> [CitedResult] {
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
