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

    private struct Metadata: Codable {
        let modelID: String
        let fingerprint: String
        let dimension: Int
        let count: Int
    }

    public func write(to directory: URL) throws {
        let data = vectors.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: directory.appendingPathComponent(Self.vectorsFilename), options: .atomic)
        // Metadata last: its presence is what says the vectors beside it are whole.
        let metadata = Metadata(modelID: modelID, fingerprint: fingerprint, dimension: dimension, count: count)
        try JSONEncoder().encode(metadata)
            .write(to: directory.appendingPathComponent(Self.metadataFilename), options: .atomic)
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
        let vectors = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return SegmentEmbeddings(modelID: modelID, fingerprint: metadata.fingerprint,
                                 dimension: metadata.dimension, vectors: vectors)
    }
}

/// Nearest passages to a question vector, as the same citations keyword search returns (F316).
public enum SemanticRanker {
    /// Below this nothing is offered. Deliberately loose: on the measured set right answers ran
    /// 0.76–0.86 and unrelated passages 0.70–0.86, so no floor separates them — this one only drops
    /// what is unrelated by any reading. Ordering, not the floor, is what the fusion relies on.
    public static let minimumSimilarity: Float = 0.76

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
public enum RankFusion {
    static let k = 60.0

    public static func fuse(lexical: [CitedResult], semantic: [CitedResult], limit: Int) -> [CitedResult] {
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
