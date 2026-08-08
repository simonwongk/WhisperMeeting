import Foundation
import Testing
@testable import WhisperCore

// F180 — BM25 keyword retrieval over segments-as-documents across a scoped meeting set. Every result
// is a citation: meeting id + (when aligned) a seekable timestamp + the supporting snippet.

private func seg(_ index: Int, _ start: Double?, _ text: String) -> SearchableSegment {
    SearchableSegment(index: index, start: start, text: text)
}

// Uniform 3-token segments so BM25 length normalization doesn't distort the term-rarity assertions.
private let idA = UUID()
private let idB = UUID()
private let corpus: [SearchableMeeting] = [
    SearchableMeeting(id: idA, title: "A", segments: [
        seg(0, 0, "pricing discount summary"),   // both query terms
        seg(1, 10, "pricing notes here"),         // pricing only (common)
        seg(2, 20, "discount notes here"),        // discount only (rare)
        seg(3, 30, "unrelated content today"),    // neither term
    ]),
    SearchableMeeting(id: idB, title: "B", segments: [
        seg(0, 0, "pricing overview slides"),     // pricing only
        seg(1, 15, "pricing review session"),     // pricing only
    ]),
]

@Test("Top result cites the segment matching the most (and rarest) query terms, with its timestamp (F180)")
func topResultCitesBestSegment() {
    let results = MeetingRetrieval.rank(query: "pricing discount", in: corpus)
    let top = try! #require(results.first)
    #expect(top.meetingID == idA)
    #expect(top.segmentIndex == 0)
    #expect(top.timestamp == 0)
    #expect(top.snippet.contains("discount"))
    #expect(top.snippet.contains("pricing"))
}

@Test("A rarer query term outranks a segment matching only the common term (BM25 IDF) (F180)")
func rareTermOutranksCommon() {
    let results = MeetingRetrieval.rank(query: "pricing discount", in: corpus)
    let discountOnly = try! #require(results.firstIndex { $0.meetingID == idA && $0.segmentIndex == 2 })
    let pricingOnly = try! #require(results.firstIndex { $0.snippet == "pricing notes here" })
    #expect(discountOnly < pricingOnly) // discount (df=2) ranks above pricing-only (df=4)
}

@Test("A segment with no query term is excluded (F180)")
func noMatchExcluded() {
    let results = MeetingRetrieval.rank(query: "pricing discount", in: corpus)
    #expect(!results.contains { $0.snippet.contains("unrelated") })
}

@Test("Every result carries a resolvable meeting id and its segment's timestamp (F180)")
func everyResultIsCited() {
    let results = MeetingRetrieval.rank(query: "pricing discount", in: corpus)
    #expect(!results.isEmpty)
    for r in results {
        #expect(r.meetingID == idA || r.meetingID == idB)
        // Every fixture segment is aligned, so each result timestamp resolves.
        #expect(r.timestamp != nil)
    }
}

@Test("An empty query returns no results (F180)")
func emptyQueryReturnsEmpty() {
    #expect(MeetingRetrieval.rank(query: "   ", in: corpus).isEmpty)
}

@Test("The result count is capped by limit (F180)")
func limitCaps() {
    #expect(MeetingRetrieval.rank(query: "pricing discount", in: corpus, limit: 2).count == 2)
}

@Test("An unaligned segment (no start) is still retrievable, cited without a timestamp (F180)")
func unalignedSegmentCitedWithoutTimestamp() {
    let idC = UUID()
    let meetings = [SearchableMeeting(id: idC, title: "C", segments: [
        seg(0, nil, "pricing discount summary"),
    ])]
    let top = try! #require(MeetingRetrieval.rank(query: "pricing", in: meetings).first)
    #expect(top.meetingID == idC)
    #expect(top.timestamp == nil)
}

@Test("A Chinese query matches via bigrams even when its characters aren't contiguous (F180)")
func chineseNonContiguousQueryMatches() {
    let idC = UUID()
    let meetings = [SearchableMeeting(id: idC, title: "预算会议", segments: [
        seg(0, 0, "我们决定把预算增加百分之十"), // contains 决定 and 预算, non-contiguous
        seg(1, 20, "其他事项下周讨论"),
    ])]
    let top = try! #require(MeetingRetrieval.rank(query: "预算决定", in: meetings).first)
    #expect(top.segmentIndex == 0)
    #expect(top.timestamp == 0)
    // Prove the naive contiguous-substring path (TextSearch) fails where bigram retrieval succeeds.
    #expect(!TextSearch.matches("预算决定", in: ["我们决定把预算增加百分之十"]))
}

@Test("A single-character CJK query matches a document where the character appears mid-run (F180)")
func singleCharChineseQueryMatches() {
    let idC = UUID()
    let meetings = [SearchableMeeting(id: idC, title: "税务", segments: [
        seg(0, 0, "我们讨论了税务问题"),   // 税 appears inside the run 税务
        seg(1, 20, "其他事项下周继续"),
    ])]
    let top = try! #require(MeetingRetrieval.rank(query: "税", in: meetings).first)
    #expect(top.meetingID == idC)
    #expect(top.segmentIndex == 0)
}

@Test("Ties break by input meeting order, then segment index (F180)")
func tieBreakStable() {
    let idX = UUID(), idY = UUID()
    let meetings = [
        SearchableMeeting(id: idX, title: "X", segments: [seg(0, 5, "budget review notes")]),
        SearchableMeeting(id: idY, title: "Y", segments: [seg(0, 5, "budget review notes")]),
    ]
    let results = MeetingRetrieval.rank(query: "budget review", in: meetings)
    #expect(results.map(\.meetingID) == [idX, idY])
}
