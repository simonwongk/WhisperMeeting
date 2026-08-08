import Foundation

/// A meeting segment prepared for cross-meeting retrieval (F180). Framework-free — the app builds these
/// from `MeetingRecord`/`TranscriptSegment` at the boundary, the same way `MeetingFacets` is built.
public struct SearchableSegment: Sendable, Equatable {
    /// Position in the meeting's segments array — the stable citation anchor.
    public let index: Int
    /// Seek timestamp in seconds; `nil` when the transcript is unaligned (Qwen/dictation) and cannot
    /// be seeked, in which case a hit still cites the meeting without an offset.
    public let start: Double?
    public let text: String

    public init(index: Int, start: Double?, text: String) {
        self.index = index
        self.start = start
        self.text = text
    }
}

/// A meeting prepared for cross-meeting retrieval (F180): its id, title, and searchable segments.
public struct SearchableMeeting: Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let segments: [SearchableSegment]

    public init(id: UUID, title: String, segments: [SearchableSegment]) {
        self.id = id
        self.title = title
        self.segments = segments
    }
}

/// One ranked, cited retrieval hit (F180): which meeting and segment, its seek timestamp (when
/// aligned), the supporting snippet, and the BM25 score used for ordering.
public struct CitedResult: Sendable, Equatable, Identifiable {
    public let meetingID: UUID
    public let meetingTitle: String
    public let segmentIndex: Int
    public let timestamp: Double?
    public let snippet: String
    public let score: Double

    public var id: String { "\(meetingID.uuidString)-\(segmentIndex)" }

    public init(
        meetingID: UUID,
        meetingTitle: String,
        segmentIndex: Int,
        timestamp: Double?,
        snippet: String,
        score: Double
    ) {
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.segmentIndex = segmentIndex
        self.timestamp = timestamp
        self.snippet = snippet
        self.score = score
    }
}

/// The tag-based scope of an "Ask Meetings" query (F180): which completed meetings to search. An empty
/// tag list means all completed meetings. (Explicit per-meeting selection is a possible later addition.)
public struct MeetingScope: Sendable, Equatable {
    public var tags: [String]
    public var tagMode: MeetingTags.MatchMode

    public init(tags: [String] = [], tagMode: MeetingTags.MatchMode = .any) {
        self.tags = tags
        self.tagMode = tagMode
    }
}

/// Pure predicate for whether a meeting is in an Ask scope (F180): completed AND matching the selected
/// tags. Reuses `MeetingTags.matches` (empty selection = all) so scope semantics match the sidebar.
public enum MeetingScopeResolver {
    public static func inScope(tags: [String], isCompleted: Bool, scope: MeetingScope) -> Bool {
        isCompleted && MeetingTags.matches(meetingTags: tags, selected: scope.tags, mode: scope.tagMode)
    }
}

/// Local BM25 keyword retrieval over segments-as-documents across a scoped meeting set (F180). Each
/// segment is one document; each returned `CitedResult` is a citation carrying its meeting, snippet,
/// and (when aligned) a seekable timestamp. This is the "normal search first" half of the Fathom
/// pattern; on-device AI answer synthesis and embedding refine are a separate follow-up that consumes
/// this same `[CitedResult]` as grounding.
public enum MeetingRetrieval {
    /// Okapi BM25 term-frequency saturation.
    static let k1 = 1.2
    /// Okapi BM25 length normalization.
    static let b = 0.75

    public static func rank(
        query: String,
        in meetings: [SearchableMeeting],
        limit: Int = 10
    ) -> [CitedResult] {
        let queryTerms = Set(RetrievalTokenizer.tokens(query))
        guard !queryTerms.isEmpty, limit > 0 else { return [] }

        struct Doc {
            let meetingOrder: Int
            let meetingID: UUID
            let meetingTitle: String
            let segmentIndex: Int
            let start: Double?
            let text: String
            let bag: [String]
            let length: Int
        }

        var docs: [Doc] = []
        var documentFrequency: [String: Int] = [:]
        for (order, meeting) in meetings.enumerated() {
            for segment in meeting.segments {
                let bag = RetrievalTokenizer.tokens(segment.text)
                guard !bag.isEmpty else { continue }
                docs.append(Doc(
                    meetingOrder: order,
                    meetingID: meeting.id,
                    meetingTitle: meeting.title,
                    segmentIndex: segment.index,
                    start: segment.start,
                    text: segment.text,
                    bag: bag,
                    length: bag.count
                ))
                for term in Set(bag).intersection(queryTerms) {
                    documentFrequency[term, default: 0] += 1
                }
            }
        }

        let documentCount = docs.count
        guard documentCount > 0 else { return [] }
        let averageLength = Double(docs.reduce(0) { $0 + $1.length }) / Double(documentCount)

        // Lucene-style non-negative IDF: `log(1 + …)` never goes negative, so a term appearing in more
        // than half of a small scoped corpus can't *subtract* score.
        var idf: [String: Double] = [:]
        for term in queryTerms {
            let df = Double(documentFrequency[term] ?? 0)
            idf[term] = log(1 + (Double(documentCount) - df + 0.5) / (df + 0.5))
        }

        var scored: [(result: CitedResult, order: Int)] = []
        for doc in docs {
            var termFrequency: [String: Int] = [:]
            for token in doc.bag where queryTerms.contains(token) {
                termFrequency[token, default: 0] += 1
            }
            guard !termFrequency.isEmpty else { continue } // no query term present → drop
            let lengthNorm = k1 * (1 - b + b * Double(doc.length) / averageLength)
            var score = 0.0
            for (term, frequency) in termFrequency {
                let f = Double(frequency)
                score += (idf[term] ?? 0) * (f * (k1 + 1)) / (f + lengthNorm)
            }
            scored.append((
                CitedResult(
                    meetingID: doc.meetingID,
                    meetingTitle: doc.meetingTitle,
                    segmentIndex: doc.segmentIndex,
                    timestamp: doc.start,
                    snippet: doc.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    score: score
                ),
                doc.meetingOrder
            ))
        }

        scored.sort { lhs, rhs in
            if lhs.result.score != rhs.result.score { return lhs.result.score > rhs.result.score }
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.result.segmentIndex < rhs.result.segmentIndex
        }
        return scored.prefix(limit).map(\.result)
    }
}
