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
// the fusion mechanics run here, and the floor/`k` sweep runs on request where the model is installed
// (F392, `floorAndFusionSweepWithTheInstalledModel` at the end of this file).
//
// **F396: the set is bilingual now, as the model and the product are.** Meetings 6 and 7 are
// Mandarin, written in Mandarin, and each pair names its language: none for the English 24, "zh" for
// a Mandarin question over a Mandarin passage, "en-zh" for an English question over a Mandarin one.
// Recall is reported per language, so a floor fitted on English alone cannot hide what it does to
// Mandarin. The English numbers stay on their own six-meeting pool, so 0.250/0.292 still mean what
// F350 measured; the Mandarin and cross-language questions are asked of the whole bilingual library.

private struct RetrievalCorpus: Decodable {
    struct Meeting: Decodable {
        let title: String
        let segments: [String]
    }

    struct Pair: Decodable {
        let question: String
        let meeting: Int
        let segment: Int
        /// nil for the English 24 (F350); "zh" or "en-zh" (F396).
        let language: String?

        var languageGroup: String { language ?? "en" }
    }

    let meetings: [Meeting]
    let pairs: [Pair]
    /// F1065: questions that name a term their passage holds, which keyword search should find.
    let exactTermPairs: [Pair]
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

/// The six English meetings F350 measured on, which the English questions are still ranked over.
private let englishMeetingCount = 6

/// The share of a question's retrieval tokens its passage also has: what BM25 sees of the pair.
///
/// `RetrievalTokenizer` gives Mandarin every character AND every bigram (F180), so a guard on it
/// reads Mandarin the way keyword search does — which is the property this guard is about. Checked
/// before relying on it (F396): a Mandarin echo of its passage scores 0.93 and the eight Mandarin
/// paraphrases 0.07–0.14, so shared single characters (的, 了, 是) do not push a paraphrase near the
/// 0.5 line, and a bigram-only variant was not needed.
private func echoOverlap(question: String, passage: String) -> Double {
    let asked = Set(RetrievalTokenizer.tokens(question))
    guard !asked.isEmpty else { return 0 }
    return Double(asked.intersection(Set(RetrievalTokenizer.tokens(passage))).count) / Double(asked.count)
}

@Test("The committed pair set is well formed and every marked passage exists (F350, F396)")
func theCorpusIsWellFormed() throws {
    let (corpus, searchable) = try loadCorpus()
    #expect(corpus.pairs.count >= 20, "the ticket asks for 20+ pairs, found \(corpus.pairs.count)")
    #expect(searchable.count == 8)
    let groups = Dictionary(grouping: corpus.pairs, by: \.languageGroup).mapValues(\.count)
    #expect(groups == ["en": 24, "zh": 8, "en-zh": 6], "got \(groups)")
    // An English question is over an English meeting, every other over a Mandarin one.
    for pair in corpus.pairs {
        #expect((pair.languageGroup == "en") == (pair.meeting < englishMeetingCount), "\(pair.question)")
    }
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

@Test("The exact-term questions name something their passage holds, and keyword search finds them (F1065)")
func exactTermQuestionsAreWhatKeywordSearchIsFor() throws {
    let (corpus, searchable) = try loadCorpus()
    let groups = Dictionary(grouping: corpus.exactTermPairs, by: \.languageGroup).mapValues(\.count)
    #expect(groups == ["en-term": 10, "zh-term": 6], "got \(groups)")
    for pair in corpus.exactTermPairs {
        let meeting = try #require(searchable.indices.contains(pair.meeting) ? searchable[pair.meeting] : nil)
        let passage = try #require(meeting.segments.indices.contains(pair.segment) ? meeting.segments[pair.segment] : nil)
        #expect((pair.languageGroup == "en-term") == (pair.meeting < englishMeetingCount), "\(pair.question)")
        // The opposite of the paraphrase guard: a question sharing nothing with its passage names no term in it.
        #expect(echoOverlap(question: pair.question, passage: passage.text) > 0, "\(pair.question) names nothing its passage holds")
    }
    #expect(Set(corpus.exactTermPairs.map { "\($0.meeting)-\($0.segment)" }).count == corpus.exactTermPairs.count)
    let expected = corpus.exactTermPairs.map { (meetingID($0.meeting), $0.segment) }
    let ranked = corpus.exactTermPairs.map { MeetingRetrieval.rank(query: $0.question, in: searchable, limit: 20) }
    let at1 = recall(at: 1, ranked: ranked, expected: expected), at3 = recall(at: 3, ranked: ranked, expected: expected)
    print("F1065 keyword recall on exact-term questions over all 8 meetings: recall@1 = \(at1), recall@3 = \(at3), n = \(expected.count)")
    #expect(at3 >= 0.75, "keyword search misses these, so they are not the questions it is for: recall@3 \(at3)")
}

@Test("The questions are paraphrases, which is what makes the set worth having (F350, F396)")
func theQuestionsDoNotEchoTheirPassages() throws {
    // The property that makes this a test of *meaning* rather than of BM25. A question sharing
    // most of its content words with the answer is answered by keyword search and measures
    // nothing — and a corpus quietly full of those is how a semantic retriever gets credited with
    // a lexical result.
    let (corpus, searchable) = try loadCorpus()
    var worst = (overlap: 0.0, question: "")
    for pair in corpus.pairs {
        let overlap = echoOverlap(question: pair.question, passage: searchable[pair.meeting].segments[pair.segment].text)
        if overlap > worst.overlap { worst = (overlap, pair.question) }
    }
    #expect(worst.overlap <= 0.5, "\"\(worst.question)\" shares \(worst.overlap) of its tokens with its answer")
}

@Test("The echo guard sees a Mandarin echo, and passes a Mandarin paraphrase (F396)")
func theEchoGuardReadsMandarin() {
    let passage = "晚的原因是应用商店审核把隐私说明退回了一次。"
    // A question that repeats its passage's words is an echo, in Mandarin as in English.
    #expect(echoOverlap(question: "应用商店审核把隐私说明退回了吗？", passage: passage) > 0.5)
    // A paraphrase sharing only single characters (是 and 因 here) is not.
    let paraphrase = "安卓上线推迟是因为什么？"
    #expect(echoOverlap(question: paraphrase, passage: passage) <= 0.5)
    // A cross-language question shares nothing lexical at all, which is why only meaning can find it.
    #expect(echoOverlap(question: "Why was the Android release late?", passage: passage) == 0)
}

@Test("Keyword recall on the committed set, which is the baseline meaning has to beat (F350)")
func keywordRecallIsMeasuredAndRecorded() throws {
    let (corpus, allMeetings) = try loadCorpus()
    // F350's English 24 over F350's six English meetings (F396): BM25's IDF depends on the pool, so
    // ranking them over the bilingual library would quietly move the numbers recorded below.
    let pairs = corpus.pairs.filter { $0.languageGroup == "en" }
    let searchable = Array(allMeetings.prefix(englishMeetingCount))
    let expected = pairs.map { (meetingID($0.meeting), $0.segment) }
    let ranked = pairs.map {
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

@Test("Keyword recall per language over the bilingual library, recorded beside the English baseline (F396)")
func keywordRecallPerLanguage() throws {
    let (corpus, searchable) = try loadCorpus()
    var report: [String] = []
    var byGroup: [String: (at1: Double, at3: Double)] = [:]
    for group in ["en", "zh", "en-zh"] {
        let pairs = corpus.pairs.filter { $0.languageGroup == group }
        let expected = pairs.map { (meetingID($0.meeting), $0.segment) }
        let ranked = pairs.map { MeetingRetrieval.rank(query: $0.question, in: searchable, limit: 20) }
        let at1 = recall(at: 1, ranked: ranked, expected: expected)
        let at3 = recall(at: 3, ranked: ranked, expected: expected)
        byGroup[group] = (at1, at3)
        report.append("\(group): recall@1 = \(at1), recall@3 = \(at3), n = \(pairs.count)")
    }
    print("F396 keyword recall over all 8 meetings — " + report.joined(separator: "; "))
    // Measured 2026-10-17: en 0.250 / 0.292 (n = 24, unchanged by the Mandarin meetings — BM25 found
    // no English token in them); **zh 0.000 / 0.875** (n = 8); **en-zh 0.000 / 0.000** (n = 6).
    //
    // The Mandarin shape is the opposite of the English one. English keyword search finds the right
    // passage first or not at all; Mandarin keyword search puts it in the top three for seven of eight
    // questions and first for none. `RetrievalTokenizer` emits every character as well as every
    // bigram, so a paraphrase still shares single characters with its passage, which is a likely
    // reason (not traced passage by passage) that it ranks near the top but under another one that
    // shares as many. So for Mandarin the keyword list carries the
    // right passage near the top, where fusion (`RankFusion.k`) decides whether it surfaces; for an
    // English question over Mandarin speech only meaning can find it at all.
    let crossLanguage = try #require(byGroup["en-zh"])
    // Structural, not a tuning claim: an English question shares no token with a Mandarin passage,
    // so keyword search cannot find one. Every such answer Ask gives comes from search by meaning,
    // which is why the floor F392 sweeps has to be fitted on these pairs and not on English alone.
    #expect(crossLanguage.at3 == 0)
    let mandarin = try #require(byGroup["zh"])
    #expect(mandarin.at3 >= mandarin.at1, "recall cannot fall as the window widens")
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

// MARK: - F392: the sweep, with the installed model

// F350 committed the set and the scorer and could not run the semantic half: the model was not installed. It is now
// (the user installed it on 2026-10-18), so this runs the sweep F392 asks for through the same `recall(at:)`, the
// app's own `SemanticRanker` and `RankFusion` (at the floor and `k` given), and the app's embedder and helper
// script. Opt-in, because it needs the model in this Mac's Application Support: `F392_MEASURE=1 swift test
// --filter floorAndFusionSweepWithTheInstalledModel`. It reads the installed model's files and the committed set,
// never a meeting. The pools are those of the keyword tests above: English questions over the six English
// meetings, Mandarin and cross-language questions over all eight. Both lists are 20 deep, as `askFusionDepth`.

/// Five numbers that say where a list of similarities sits.
private func spread(_ values: [Float]) -> String {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return "none" }
    func at(_ q: Double) -> Float { sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))] }
    return String(format: "min %.3f · p25 %.3f · median %.3f · p75 %.3f · max %.3f (n %d)",
                  at(0), at(0.25), at(0.5), at(0.75), at(1), sorted.count)
}

@Test("Ask's floor and fusion k against the committed set, with the installed search model (F392)",
      .enabled(if: ProcessInfo.processInfo.environment["F392_MEASURE"] == "1"))
func floorAndFusionSweepWithTheInstalledModel() async throws {
    let (corpus, allMeetings) = try loadCorpus()
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Scripts/embed_local.py")
    let embedder = LocalEmbedder(helperScriptURL: script)
    let passageTexts = allMeetings.flatMap { $0.segments.map(\.text) }
    let passages = try await embedder.embed(passageTexts, kind: .passage)
    // The paraphrases first, then F1065's exact-term questions, so a pair's row is its index in `asked`.
    let asked = corpus.pairs + corpus.exactTermPairs
    let questions = try await embedder.embed(asked.map(\.question), kind: .query)
    let dimension = passages.dimension
    try #require(dimension == 384 && questions.dimension == dimension)
    try #require(passages.vectors.count == passageTexts.count * dimension)
    var indexes: [(meeting: SearchableMeeting, index: SegmentEmbeddings)] = []
    var row = 0
    for meeting in allMeetings {
        let rows = meeting.segments.count
        indexes.append((meeting, SegmentEmbeddings(
            modelID: AskEmbeddingRuntime.modelID, fingerprint: "", dimension: dimension,
            vectors: Array(passages.vectors[(row * dimension)..<((row + rows) * dimension)]))))
        row += rows
    }
    func query(_ pair: Int) -> [Float] { Array(questions.vectors[(pair * dimension)..<((pair + 1) * dimension)]) }
    func dot(_ a: [Float], _ b: ArraySlice<Float>) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }

    var lines: [String] = []
    for group in ["en", "zh", "en-zh"] {
        let members = corpus.pairs.indices.filter { corpus.pairs[$0].languageGroup == group }
        let pool = group == "en" ? englishMeetingCount : allMeetings.count
        let poolIndexes = Array(indexes.prefix(pool))
        let poolMeetings = Array(allMeetings.prefix(pool))
        let expected = members.map { (meetingID(corpus.pairs[$0].meeting), corpus.pairs[$0].segment) }

        // 1. The two populations: each question's similarity to its own passage, and to every other one in its pool.
        var correct: [Float] = [], unrelated: [Float] = [], bestUnrelated: [Float] = []
        for member in members {
            let pair = corpus.pairs[member], q = query(member)
            var best: Float = -1
            for (m, entry) in poolIndexes.enumerated() {
                for s in 0..<entry.index.count {
                    let similarity = dot(q, entry.index.vectors[(s * dimension)..<((s + 1) * dimension)])
                    if m == pair.meeting && s == pair.segment { correct.append(similarity) } else {
                        unrelated.append(similarity)
                        best = max(best, similarity)
                    }
                }
            }
            bestUnrelated.append(best)
        }
        lines.append("[\(group)] correct: \(spread(correct))")
        lines.append("[\(group)] unrelated: \(spread(unrelated))")
        lines.append("[\(group)] best unrelated per question: \(spread(bestUnrelated))")

        // 2. Meaning alone at each floor.
        for floor: Float in [0, 0.70, 0.76, 0.80] {
            let ranked = members.map { SemanticRanker.rank(query: query($0), in: poolIndexes, limit: 20, floor: floor) }
            lines.append(String(format: "[%@] meaning only, floor %.2f: recall@1 %.3f · recall@3 %.3f · recall@5 %.3f · mean list %.1f",
                                group, floor, recall(at: 1, ranked: ranked, expected: expected),
                                recall(at: 3, ranked: ranked, expected: expected), recall(at: 5, ranked: ranked, expected: expected),
                                Double(ranked.map(\.count).reduce(0, +)) / Double(ranked.count)))
        }

        // 3. Fused, at each k, over the floor in use and the one F329 moved from; and where F182's five come from.
        let lexical = members.map { MeetingRetrieval.rank(query: corpus.pairs[$0].question, in: poolMeetings, limit: 20) }
        lines.append(String(format: "[%@] keyword only: recall@1 %.3f · recall@3 %.3f · recall@5 %.3f", group,
                            recall(at: 1, ranked: lexical, expected: expected), recall(at: 3, ranked: lexical, expected: expected),
                            recall(at: 5, ranked: lexical, expected: expected)))
        for floor: Float in [0.70, 0.76] {
            let semantic = members.map { SemanticRanker.rank(query: query($0), in: poolIndexes, limit: 20, floor: floor) }
            for k in fusionConstants {
                let fused = zip(lexical, semantic).map { RankFusion.fuse(lexical: $0, semantic: $1, limit: 20, k: k) }
                var both = 0, keywordOnly = 0, meaningOnly = 0
                for ((top, keyword), meaning) in zip(zip(fused, lexical), semantic) {
                    for hit in top.prefix(5) {
                        let inKeyword = keyword.contains { $0.id == hit.id }, inMeaning = meaning.contains { $0.id == hit.id }
                        if inKeyword && inMeaning { both += 1 } else if inKeyword { keywordOnly += 1 } else if inMeaning { meaningOnly += 1 }
                    }
                }
                lines.append(String(format: "[%@] fused, floor %.2f, k %3.0f: recall@1 %.3f · recall@3 %.3f · recall@5 %.3f · top five: both %d, keyword only %d, meaning only %d",
                                    group, floor, k, recall(at: 1, ranked: fused, expected: expected),
                                    recall(at: 3, ranked: fused, expected: expected), recall(at: 5, ranked: fused, expected: expected),
                                    both, keywordOnly, meaningOnly))
            }
        }
    }
    // F1065: the questions keyword search is for, over the whole library — what a smaller `k` may cost them.
    for group in ["en-term", "zh-term"] {
        let members = asked.indices.filter { $0 >= corpus.pairs.count && asked[$0].languageGroup == group }
        let expected = members.map { (meetingID(asked[$0].meeting), asked[$0].segment) }
        let lexical = members.map { MeetingRetrieval.rank(query: asked[$0].question, in: allMeetings, limit: 20) }
        let semantic = members.map { SemanticRanker.rank(query: query($0), in: indexes, limit: 20, floor: 0.70) }
        lines.append(String(format: "[%@] keyword only: recall@1 %.3f · recall@3 %.3f · recall@5 %.3f · meaning only: recall@1 %.3f · recall@3 %.3f · recall@5 %.3f",
                            group, recall(at: 1, ranked: lexical, expected: expected), recall(at: 3, ranked: lexical, expected: expected),
                            recall(at: 5, ranked: lexical, expected: expected), recall(at: 1, ranked: semantic, expected: expected),
                            recall(at: 3, ranked: semantic, expected: expected), recall(at: 5, ranked: semantic, expected: expected)))
        for k in fusionConstants {
            let fused = zip(lexical, semantic).map { RankFusion.fuse(lexical: $0, semantic: $1, limit: 20, k: k) }
            lines.append(String(format: "[%@] fused, floor 0.70, k %3.0f: recall@1 %.3f · recall@3 %.3f · recall@5 %.3f", group, k,
                                recall(at: 1, ranked: fused, expected: expected), recall(at: 3, ranked: fused, expected: expected),
                                recall(at: 5, ranked: fused, expected: expected)))
        }
    }
    print("F392 sweep (\(AskEmbeddingRuntime.modelID)):\n" + lines.joined(separator: "\n"))
}

/// The fusion constants the sweep tries: F392's five, and the small ones F1065 found mattered.
private let fusionConstants: [Double] = [1, 2, 3, 5, 10, 20, 60]
