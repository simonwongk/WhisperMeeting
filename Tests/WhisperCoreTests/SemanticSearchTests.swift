import Foundation
import Testing
@testable import WhisperCore

// F316 — search by meaning beside the keyword search. The keyword ranker (BM25) stays the baseline;
// a per-meeting embedding index adds the passages that share no words with the question, and the
// two lists are merged by reciprocal rank fusion, which needs no tuning and no score calibration —
// and e5's cosines cannot be calibrated: on the measured set, right answers ran 0.76–0.86 and wrong
// ones 0.70–0.86.

private func meeting(_ title: String, _ texts: [String]) -> SearchableMeeting {
    SearchableMeeting(id: UUID(), title: title, segments: texts.enumerated().map {
        SearchableSegment(index: $0.offset, start: Double($0.offset) * 10, text: $0.element)
    })
}

private func unit(_ values: [Float]) -> [Float] {
    let norm = values.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return values.map { $0 / norm }
}

@Test("An index round-trips through its two files and refuses a stale or foreign one (F316)")
func embeddingIndexRoundTrips() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SemanticIndex-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let texts = ["alpha", "beta"]
    let index = SegmentEmbeddings(modelID: "m1", fingerprint: SegmentEmbeddings.fingerprint(of: texts),
                                  dimension: 2, vectors: [1, 0, 0, 1])
    try index.write(to: root)

    #expect(SegmentEmbeddings.read(from: root, modelID: "m1", texts: texts) == index)
    #expect(SegmentEmbeddings.read(from: root, modelID: "m1", texts: ["alpha", "edited"]) == nil, "the transcript changed")
    #expect(SegmentEmbeddings.read(from: root, modelID: "m2", texts: texts) == nil, "another model's vectors are not comparable")
    try Data([1, 2, 3]).write(to: root.appendingPathComponent(SegmentEmbeddings.vectorsFilename))
    #expect(SegmentEmbeddings.read(from: root, modelID: "m1", texts: texts) == nil, "a truncated file is no index")
}

@Test("The nearest passages by cosine come back as citations, junk below the floor does not (F316)")
func semanticRankerReturnsNearestPassages() {
    let m = meeting("Planning", ["pricing", "offsite", "hiring"])
    let index = SegmentEmbeddings(modelID: "m", fingerprint: "f", dimension: 2,
                                  vectors: unit([1, 0.1]) + unit([0.1, 1]) + unit([-1, 0]))
    let hits = SemanticRanker.rank(query: unit([1, 0]), in: [(m, index)], limit: 5)
    #expect(hits.map(\.snippet) == ["pricing"])
    #expect(hits.first?.timestamp == 0 && hits.first?.meetingTitle == "Planning")
    #expect(hits.first.map { $0.score > 0.99 } == true)
}

@Test("Fusion keeps what both rankers found at the top and admits what only one found (F316)")
func fusionMergesTheTwoRankings() {
    func hit(_ id: UUID, _ segment: Int, _ text: String) -> CitedResult {
        CitedResult(meetingID: id, meetingTitle: "M", segmentIndex: segment, timestamp: nil, snippet: text, score: 1)
    }
    let id = UUID()
    let lexical = [hit(id, 0, "keyword only"), hit(id, 1, "both")]
    let semantic = [hit(id, 1, "both"), hit(id, 2, "meaning only")]
    let fused = RankFusion.fuse(lexical: lexical, semantic: semantic, limit: 10)
    #expect(fused.map(\.snippet) == ["both", "keyword only", "meaning only"])
    #expect(RankFusion.fuse(lexical: lexical, semantic: [], limit: 10).map(\.snippet) == ["keyword only", "both"],
            "with no index the result is exactly the keyword search")
    #expect(RankFusion.fuse(lexical: lexical, semantic: semantic, limit: 2).count == 2)
}

// F329/F330 — what the floor and the fusion constant actually do at this scale. Both were described
// in comments that the values contradicted, and neither effect was pinned by a test.

@Test("The similarity floor drops the unrelated, not the bottom of the correct range (F329)")
func semanticFloorSitsBelowTheCorrectRange() {
    // Unit vectors, so the ranker's raw dot product IS the cosine. 0.755 is inside the measured
    // correct range (0.76–0.86) by less than one part in a hundred — the old floor dropped it.
    func atCosine(_ cosine: Float) -> [Float] {
        [cosine, (1 - cosine * cosine).squareRoot()]
    }
    let m = meeting("Planning", ["just under the old floor", "unrelated"])
    let index = SegmentEmbeddings(modelID: "m", fingerprint: "f", dimension: 2,
                                  vectors: atCosine(0.755) + atCosine(0.2))
    let hits = SemanticRanker.rank(query: [1, 0], in: [(m, index)], limit: 5)
    #expect(hits.map(\.snippet) == ["just under the old floor"])
    #expect(SemanticRanker.minimumSimilarity == 0.70)
}

@Test("A passage in both lists outranks a perfect paraphrase in one (F330)")
func fusionRanksCoOccurrenceAboveEveryone() {
    // The scale effect, not a hypothetical: with both lists capped at 20 the best single-list score
    // is 1/61 and the worst is 1/80, while any co-occurring document scores at least 2/80. So rank
    // stops mattering the moment a document appears twice.
    func hit(_ segment: Int, _ text: String) -> CitedResult {
        CitedResult(meetingID: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(segment % 10)")!,
                    meetingTitle: "M", segmentIndex: segment, timestamp: nil, snippet: text, score: 1)
    }
    let mediocre = hit(9, "in both lists, last in each")
    let paraphrase = hit(1, "the perfect paraphrase")
    let lexical = (0..<19).map { hit($0 + 20, "filler \($0)") } + [mediocre]
    let semantic = [paraphrase] + (0..<18).map { hit($0 + 40, "other \($0)") } + [mediocre]

    let fused = RankFusion.fuse(lexical: lexical, semantic: semantic, limit: 3)
    #expect(fused.first?.snippet == "in both lists, last in each")
    #expect(fused.map(\.snippet).contains("the perfect paraphrase"))
}

@Test("Single-list passages tie exactly, and the tie breaks toward keyword (F330)")
func fusionBreaksExactTiesTowardKeyword() {
    func hit(_ segment: Int, _ text: String) -> CitedResult {
        CitedResult(meetingID: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02d", segment))")!,
                    meetingTitle: "M", segmentIndex: segment, timestamp: nil, snippet: text, score: 1)
    }
    let lexical = [hit(1, "L1"), hit(2, "L2"), hit(3, "L3")]
    let semantic = [hit(4, "S1"), hit(5, "S2"), hit(6, "S3")]

    // Nothing co-occurs, so every score at equal rank is bit-identical and only insertion order
    // decides. `lexical` is enumerated first, so the fused list alternates with keyword leading —
    // which is why F182's five grounding passages hold at most two meaning-only ones.
    let fused = RankFusion.fuse(lexical: lexical, semantic: semantic, limit: 6)
    #expect(fused.map(\.snippet) == ["L1", "S1", "L2", "S2", "L3", "S3"])
    #expect(Array(fused.prefix(5).map(\.snippet).filter { $0.hasPrefix("S") }).count == 2,
            "the answer model sees two meaning-only passages out of five")
}
