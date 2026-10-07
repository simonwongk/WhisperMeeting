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

/// One meeting's segments split into the terms keyword search ranks on — the expensive half of a
/// rank, done once per version of the meeting's text and reused by every query after it (F538).
///
/// `MeetingRetrieval.rank` used to tokenize every segment of every in-scope meeting on every query,
/// on the main actor, twice per Ask when search by meaning is installed. Compact on purpose, because
/// Ask keeps one per meeting for the session: each distinct term is stored once, sorted so a query
/// term is found by binary search, and every token is a 4-byte position in that list — so a rank
/// reads integers, and skips a meeting outright when it holds none of the query's terms.
public struct MeetingTermIndex: Sendable {
    public let meeting: SearchableMeeting
    /// The meeting's distinct terms, sorted.
    let terms: [String]
    /// Every segment's tokens in order, as positions in `terms`.
    let tokens: [UInt32]
    /// Where each segment's tokens start in `tokens`, plus the end: one more entry than segments.
    let offsets: [Int]
    /// Segments with at least one token; a segment with none is not a document.
    let documentCount: Int

    /// What a cache of these bounds its memory by.
    public var tokenCount: Int { tokens.count }

    public init(_ meeting: SearchableMeeting) {
        var ids: [String: UInt32] = [:]
        var firstSeen: [String] = []
        var raw: [UInt32] = []
        var offsets: [Int] = [0]
        offsets.reserveCapacity(meeting.segments.count + 1)
        var documentCount = 0
        for segment in meeting.segments {
            let bag = RetrievalTokenizer.tokens(segment.text)
            if !bag.isEmpty { documentCount += 1 }
            for token in bag {
                if let id = ids[token] {
                    raw.append(id)
                } else {
                    // Clamping cannot bite: 2^32 distinct terms in one meeting is far beyond memory.
                    let id = UInt32(clamping: firstSeen.count)
                    ids[token] = id
                    firstSeen.append(token)
                    raw.append(id)
                }
            }
            offsets.append(raw.count)
        }
        // Renumber in sorted order so the dictionary need not be kept for lookups.
        let order = firstSeen.indices.sorted { firstSeen[$0] < firstSeen[$1] }
        var renumbered = [UInt32](repeating: 0, count: firstSeen.count)
        for (sorted, original) in order.enumerated() { renumbered[original] = UInt32(clamping: sorted) }
        self.meeting = meeting
        self.terms = order.map { firstSeen[$0] }
        self.tokens = raw.map { renumbered[Int($0)] }
        self.offsets = offsets
        self.documentCount = documentCount
    }

    /// The term's position in `terms`, or nil when no segment of this meeting has it.
    func termID(_ term: String) -> UInt32? {
        var low = 0
        var high = terms.count
        while low < high {
            let middle = (low + high) / 2
            if terms[middle] < term { low = middle + 1 } else { high = middle }
        }
        return low < terms.count && terms[low] == term ? UInt32(clamping: low) : nil
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

    /// Tokenizes every meeting, then ranks — for a caller with nothing to reuse. Ask keeps each
    /// meeting's `MeetingTermIndex` and calls the overload below (F538).
    public static func rank(
        query: String,
        in meetings: [SearchableMeeting],
        limit: Int = 10
    ) -> [CitedResult] {
        guard limit > 0, !RetrievalTokenizer.tokens(query).isEmpty else { return [] }
        return rank(query: query, in: meetings.map(MeetingTermIndex.init), limit: limit)
    }

    public static func rank(
        query: String,
        in indexes: [MeetingTermIndex],
        limit: Int = 10
    ) -> [CitedResult] {
        // Sorted, so every document sums its terms in one fixed order: two documents with the same
        // terms score bit-identically and fall to the tie-break below. The per-document dictionary
        // this replaced summed in hash order, so equal documents differed in the last bit and the
        // documented meeting-order tie-break was skipped at random.
        let terms = Set(RetrievalTokenizer.tokens(query)).sorted()
        guard !terms.isEmpty, limit > 0 else { return [] }

        // One pass: the corpus totals BM25 needs, and every segment holding a query term together
        // with how often it holds each one (`frequencies`, `terms.count` per candidate).
        var documentCount = 0
        var totalLength = 0
        var documentFrequency = [Int](repeating: 0, count: terms.count)
        var candidates: [(meeting: Int, position: Int, length: Int)] = []
        var frequencies: [Int32] = []
        var counts = [Int32](repeating: 0, count: terms.count)
        for (order, index) in indexes.enumerated() {
            documentCount += index.documentCount
            totalLength += index.tokens.count
            let present: [(slot: Int, id: UInt32)] = terms.indices.compactMap { slot in
                index.termID(terms[slot]).map { (slot, $0) }
            }
            guard !present.isEmpty else { continue }
            for position in 0..<(index.offsets.count - 1) {
                let start = index.offsets[position]
                let end = index.offsets[position + 1]
                var matched = false
                for token in index.tokens[start..<end] {
                    for term in present where term.id == token {
                        counts[term.slot] += 1
                        matched = true
                    }
                }
                guard matched else { continue }
                candidates.append((order, position, end - start))
                for slot in counts.indices where counts[slot] > 0 { documentFrequency[slot] += 1 }
                frequencies.append(contentsOf: counts)
                for slot in counts.indices { counts[slot] = 0 }
            }
        }
        guard documentCount > 0, !candidates.isEmpty else { return [] }
        let averageLength = Double(totalLength) / Double(documentCount)

        // Lucene-style non-negative IDF: `log(1 + …)` never goes negative, so a term appearing in more
        // than half of a small scoped corpus can't *subtract* score.
        let idf = documentFrequency.map { df in
            log(1 + (Double(documentCount) - Double(df) + 0.5) / (Double(df) + 0.5))
        }

        var scored: [(score: Double, order: Int, segmentIndex: Int, candidate: Int)] = []
        scored.reserveCapacity(candidates.count)
        for (number, candidate) in candidates.enumerated() {
            let lengthNorm = k1 * (1 - b + b * Double(candidate.length) / averageLength)
            var score = 0.0
            for slot in terms.indices {
                let f = Double(frequencies[number * terms.count + slot])
                guard f > 0 else { continue }
                score += idf[slot] * (f * (k1 + 1)) / (f + lengthNorm)
            }
            let segmentIndex = indexes[candidate.meeting].meeting.segments[candidate.position].index
            scored.append((score, candidate.meeting, segmentIndex, number))
        }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.segmentIndex < rhs.segmentIndex
        }
        // Only the results kept are built, so a common word matching a hundred thousand segments
        // trims and copies twenty snippets, not all of them.
        return scored.prefix(limit).map { entry in
            let candidate = candidates[entry.candidate]
            let meeting = indexes[candidate.meeting].meeting
            let segment = meeting.segments[candidate.position]
            return CitedResult(
                meetingID: meeting.id,
                meetingTitle: meeting.title,
                segmentIndex: segment.index,
                timestamp: segment.start,
                snippet: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                score: entry.score
            )
        }
    }
}
