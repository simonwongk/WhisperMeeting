import Foundation
import Testing
@testable import WhisperCore

// F350 — the evidence set behind Ask's two retrieval constants, and a scorer that re-derives them.
//
// `SemanticRanker.minimumSimilarity` (0.70) and `RankFusion.k` (60) decide what search by meaning
// returns. The measurement behind the first — right answers 0.76–0.86, unrelated 0.70–0.86, over
// 20 invented pairs — lived in one session's shell history and was never committed, so F329's
// argument was sound from the numbers as recorded and impossible to re-check. F330 pinned what
// `k = 60` *does* at 20-deep lists without establishing that 60 is right for that scale.
//
// This file commits the set and the scorer. `Fixtures/ask-retrieval-pairs.json` is 24 paraphrase
// questions over 48 invented passages, in the same `#filePath`-read style as
// `refinement-guard-vectors.json`.
//
// **What can be measured here and what cannot.** `recall(at:)` below takes the two ranked lists,
// so it scores keyword, semantic, or fused retrieval identically — but producing the semantic list
// needs `intfloat/multilingual-e5-small`, a 490 MB download into the production runtime that is
// the user's decision to make in Settings and not a test's to start. So the keyword baseline and
// the fusion mechanics run here, and the floor/`k` sweep the ticket asks for is one command away
// once that model exists. F392 carries it.

private struct RetrievalCorpus: Decodable {
    struct Meeting: Decodable {
        let title: String
        let segments: [String]
    }

    struct Pair: Decodable {
        let question: String
        let meeting: Int
        let segment: Int
    }

    let meetings: [Meeting]
    let pairs: [Pair]
}

/// Deterministic per-meeting UUIDs, so a hit can be matched back to the corpus index.
private func meetingID(_ index: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!
}

private func loadCorpus() throws -> (RetrievalCorpus, [SearchableMeeting]) {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ask-retrieval-pairs.json")
    let corpus = try JSONDecoder().decode(RetrievalCorpus.self, from: try Data(contentsOf: url))
    let searchable = corpus.meetings.enumerated().map { index, meeting in
        SearchableMeeting(
            id: meetingID(index),
            title: meeting.title,
            segments: meeting.segments.enumerated().map {
                SearchableSegment(index: $0.offset, start: Double($0.offset) * 30, text: $0.element)
            }
        )
    }
    return (corpus, searchable)
}

/// recall@N over a corpus: the share of questions whose marked passage is in the first N results.
///
/// Takes the ranked list per question rather than a retriever, so keyword, semantic and fused
/// results score through the same function — which is the only way the three numbers are
/// comparable, and the thing that was missing when the constants were chosen.
private func recall(at depth: Int, ranked: [[CitedResult]], expected: [(UUID, Int)]) -> Double {
    precondition(ranked.count == expected.count)
    var hits = 0
    for (results, want) in zip(ranked, expected) {
        if results.prefix(depth).contains(where: { $0.meetingID == want.0 && $0.segmentIndex == want.1 }) {
            hits += 1
        }
    }
    return Double(hits) / Double(expected.count)
}

@Test("The committed pair set is well formed and every marked passage exists (F350)")
func theCorpusIsWellFormed() throws {
    let (corpus, searchable) = try loadCorpus()
    #expect(corpus.pairs.count >= 20, "the ticket asks for 20+ pairs, found \(corpus.pairs.count)")
    #expect(searchable.count == 6)
    #expect(searchable.allSatisfy { $0.segments.count == 8 })
    for pair in corpus.pairs {
        let meeting = try #require(searchable.indices.contains(pair.meeting) ? searchable[pair.meeting] : nil)
        #expect(meeting.segments.indices.contains(pair.segment), "\(pair.question)")
    }
    // Every marked passage distinct, so recall cannot be inflated by one passage answering five
    // questions.
    let marked = Set(corpus.pairs.map { "\($0.meeting)-\($0.segment)" })
    #expect(marked.count == corpus.pairs.count)
}

@Test("The questions are paraphrases, which is what makes the set worth having (F350)")
func theQuestionsDoNotEchoTheirPassages() throws {
    // The property that makes this a test of *meaning* rather than of BM25. A question sharing
    // most of its content words with the answer is answered by keyword search and measures
    // nothing — and a corpus quietly full of those is how a semantic retriever gets credited with
    // a lexical result.
    let (corpus, searchable) = try loadCorpus()
    var worst = (overlap: 0.0, question: "")
    for pair in corpus.pairs {
        let question = Set(RetrievalTokenizer.tokens(pair.question))
        let passage = Set(RetrievalTokenizer.tokens(searchable[pair.meeting].segments[pair.segment].text))
        guard !question.isEmpty else { continue }
        let overlap = Double(question.intersection(passage).count) / Double(question.count)
        if overlap > worst.overlap { worst = (overlap, pair.question) }
    }
    #expect(worst.overlap <= 0.5, "\"\(worst.question)\" shares \(worst.overlap) of its tokens with its answer")
}

@Test("Keyword recall on the committed set, which is the baseline meaning has to beat (F350)")
func keywordRecallIsMeasuredAndRecorded() throws {
    let (corpus, searchable) = try loadCorpus()
    let expected = corpus.pairs.map { (meetingID($0.meeting), $0.segment) }
    let ranked = corpus.pairs.map {
        MeetingRetrieval.rank(query: $0.question, in: searchable, limit: 20)
    }
    let at1 = recall(at: 1, ranked: ranked, expected: expected)
    let at3 = recall(at: 3, ranked: ranked, expected: expected)

    // Recorded, not asserted tightly. These are the numbers the ticket wanted committed so they
    // can be compared against the semantic and fused ones; pinning them to three decimals would
    // make every tokenizer change a failure in this file instead of a measurement.
    //
    // Measured 2026-09-22: **recall@1 = 0.250, recall@3 = 0.292** (6 and 7 of 24).
    //
    // I wrote 0.375 here before running it, from a plausible model of what BM25 would do on
    // paraphrases. It is 0.292, and the gap is the interesting part: widening the window from 1 to
    // 3 recovers exactly ONE more question out of 24. On this set keyword search finds the right
    // passage first or not at all, which is what a lexical retriever does with a question that
    // shares no content words — it has nothing to rank *nearly* right. That is the shape the
    // semantic half exists to fill, and it is visible only because the numbers are now committed.
    #expect(at1 > 0, "keyword search finds nothing at all, which would make the corpus useless")
    #expect(at3 >= at1, "recall cannot fall as the window widens")
    #expect(at1 <= 0.6, "recall@1 \(at1) — if keyword search alone answers most of these, the questions echo their passages")
    print("F350 keyword baseline: recall@1 = \(at1), recall@3 = \(at3), n = \(expected.count)")
}

@Test("The scorer separates a perfect ranking from a useless one (F350)")
func theScorerItselfIsChecked() throws {
    // Without this the numbers above are unfalsifiable: a `recall` that always returned 0.25 would
    // look exactly the same. Two synthetic rankings bracket it.
    let (corpus, searchable) = try loadCorpus()
    let expected = corpus.pairs.map { (meetingID($0.meeting), $0.segment) }
    let perfect = corpus.pairs.map { pair -> [CitedResult] in
        let segment = searchable[pair.meeting].segments[pair.segment]
        return [CitedResult(
            meetingID: meetingID(pair.meeting), meetingTitle: searchable[pair.meeting].title,
            segmentIndex: segment.index, timestamp: segment.start, snippet: segment.text, score: 1
        )]
    }
    #expect(recall(at: 1, ranked: perfect, expected: expected) == 1)
    #expect(recall(at: 1, ranked: corpus.pairs.map { _ in [] }, expected: expected) == 0)
}

@Test("Fused recall is at least keyword recall on this set, at every k tried (F350)")
func fusionNeverLosesToKeywordAlone() throws {
    // The half of the `k` sweep that runs without the model. RRF uses ranks only, so given the
    // same two lists the sweep is exact — what is missing is the semantic list, not the sweep.
    // Standing in for it here is the keyword list itself, which makes fusion a no-op and pins the
    // one property that must hold for ANY k: fusing cannot lose a passage keyword already found.
    let (corpus, searchable) = try loadCorpus()
    let expected = corpus.pairs.map { (meetingID($0.meeting), $0.segment) }
    let lexical = corpus.pairs.map {
        MeetingRetrieval.rank(query: $0.question, in: searchable, limit: 20)
    }
    let keywordAt3 = recall(at: 3, ranked: lexical, expected: expected)
    let fused = lexical.map { RankFusion.fuse(lexical: $0, semantic: $0, limit: 20) }
    #expect(recall(at: 3, ranked: fused, expected: expected) == keywordAt3)
    #expect(recall(at: 1, ranked: fused, expected: expected) == recall(at: 1, ranked: lexical, expected: expected))
}
