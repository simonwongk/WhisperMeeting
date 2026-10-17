import Foundation
import Testing
@testable import WhisperCore

// F658 — the F572 review's simulation, as a seeded test. Every sentence of a long meeting is known,
// so a row's offered text can be read back as the sentences it carries and checked against the
// sentences of its line: Replace may offer only a line's own sentences, and all of those the other
// engine heard. `referenceCompare` shares every rule with `compare`, so the randomized F542 test can
// never see a rule that is wrong in both; this one measures against what was actually said.
//
// The model: 6,000 sentences, one word each so a sentence is recognisable in any text ("w17" in this
// transcript, "v17" where the other engine heard it differently). A quarter are short (a "Yeah." or
// "OK, sure.": 0.6–1.5 s, or 1–1.5 s where a test says so), the rest 1.5–6 s, with no pause or a
// pause of up to 0.8 s between them.
// Each engine groups consecutive sentences into lines of one to three; this transcript's boundaries
// are the sentences' own, and the other engine's are moved by up to ±jitter, independently at each
// end. The other engine hears a sentence differently three times in ten and misses one in thirty.
// Two groupings: the same for both engines (the case the review measured the short-neighbour
// duplication in) and independent.
//
// Every guarantee below rests on that model, and in particular on this transcript's boundaries
// being the sentences' own, so that all disagreement is the other engine's jitter. With both
// engines' boundaries jittered by ±0.5 s the lane R review measured 3 of 827 offered rows dropping
// words even for 1 s sentences, and the offer rate falling to ~50 % / ~9 %. `primaryJitter` widens the
// model to that case (F872); the test that uses it is at the end, and F872's log entry has the real
// Whisper/Qwen pair measured on one clip.

/// A deterministic generator (SplitMix64), so a failure names a configuration that can be re-run.
private struct SplitMix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in `range`.
    mutating func uniform(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + Double(next() >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
    }
    mutating func chance(_ probability: Double) -> Bool { uniform(0...1) < probability }
    mutating func lineSize() -> Int {
        let roll = uniform(0...1)
        return roll < 0.6 ? 1 : roll < 0.9 ? 2 : 3
    }
}

private struct Meeting {
    var primary: [TranscriptSegment] = []
    var secondary: [TranscriptSegment] = []
    /// The sentences of each line of `primary`.
    var lineSentences: [[Int]] = []
    /// The sentences the other engine heard at all.
    var heard: Set<Int> = []
    /// The sentences of each segment of `secondary`, those it heard differently, and each sentence's
    /// length — what `realWords` needs to write the same meeting in real words (review of F868).
    var secondarySentences: [[Int]] = []
    var heardDifferently: Set<Int> = []
    var seconds: [Double] = []
}

private func simulate(seed: UInt64, jitter: Double, sameSplit: Bool, sentences count: Int = 6_000,
                      shortest: Double = 0.6, primaryJitter: Double = 0) -> Meeting {
    var rng = SplitMix(state: seed)
    var spans: [(start: Double, end: Double)] = []
    var clock = 0.0
    for _ in 0..<count {
        let length = rng.chance(0.25) ? rng.uniform(shortest...1.5) : rng.uniform(1.5...6.0)
        spans.append((clock, clock + length))
        clock += length + (rng.chance(0.5) ? 0 : rng.uniform(0.05...0.8))
    }
    func groups(_ rng: inout SplitMix) -> [[Int]] {
        var result: [[Int]] = []
        var next = 0
        while next < count {
            let size = min(rng.lineSize(), count - next)
            result.append(Array(next..<(next + size)))
            next += size
        }
        return result
    }
    var meeting = Meeting()
    let primaryGroups = groups(&rng)
    let secondaryGroups = sameSplit ? primaryGroups : groups(&rng)
    // F872: with `primaryJitter`, this transcript's own boundaries move too, drawn from a generator of
    // their own so the other engine's draws — and so every configuration measured before — are unchanged.
    var primaryRNG = SplitMix(state: seed ^ 0xF872_F872_F872_F872)
    for group in primaryGroups {
        let start = spans[group.first!].start + (primaryJitter > 0 ? primaryRNG.uniform(-primaryJitter...primaryJitter) : 0)
        let end = max(start + 0.05, spans[group.last!].end + (primaryJitter > 0 ? primaryRNG.uniform(-primaryJitter...primaryJitter) : 0))
        meeting.primary.append(TranscriptSegment(
            speaker: nil, start: start, end: end,
            text: group.map { "w\($0)." }.joined(separator: " ")
        ))
        meeting.lineSentences.append(group)
    }
    for group in secondaryGroups {
        let said = group.filter { _ in !rng.chance(1.0 / 30) }
        let words = said.map { rng.chance(0.3) ? "v\($0)." : "w\($0)." }
        guard !said.isEmpty else { continue }
        meeting.heard.formUnion(said)
        meeting.secondarySentences.append(said)
        meeting.heardDifferently.formUnion(zip(said, words).filter { $0.1.hasPrefix("v") }.map(\.0))
        let start = spans[group.first!].start + rng.uniform(-jitter...jitter)
        let end = max(start + 0.05, spans[group.last!].end + rng.uniform(-jitter...jitter))
        meeting.secondary.append(TranscriptSegment(speaker: nil, start: start, end: end, text: words.joined(separator: " ")))
    }
    meeting.seconds = spans.map { $0.end - $0.start }
    return meeting
}

/// The sentences a text carries: "w17. v18." → [17, 18].
private func sentences(in text: String) -> [Int] {
    text.split(separator: " ").compactMap { word in Int(word.dropFirst().dropLast()) }
}

private struct Tally: CustomStringConvertible {
    var diverging = 0
    var offered = 0
    /// Offered rows carrying a sentence that is not in the line: Replace writes it twice.
    var outside = 0
    /// Offered rows missing a sentence of the line that the other engine did hear: Replace deletes it.
    var dropped = 0
    var description: String {
        "diverging=\(diverging) offered=\(offered) outside=\(outside) dropped=\(dropped)"
    }
}

/// What Replace would do on every diverging row of `meeting`, if offered where `offering` says.
private func tally(_ meeting: Meeting, offering: (TranscriptComparisonSpan) -> Bool) -> Tally {
    var result = Tally()
    for (line, span) in TranscriptComparison.compare(meeting.primary, meeting.secondary).enumerated()
    where span.kind == .diverge {
        result.diverging += 1
        guard offering(span), let text = span.secondaryText else { continue }
        result.offered += 1
        let offered = Set(sentences(in: text))
        let own = Set(meeting.lineSentences[line])
        if !offered.isSubset(of: own) { result.outside += 1 }
        if !own.intersection(meeting.heard).isSubset(of: offered) { result.dropped += 1 }
    }
    return result
}

/// Three seeds of each configuration: one meeting is 6,000 sentences, so three is about 50,000
/// diverging rows across the six configurations.
private func run(jitter: Double, sameSplit: Bool, shortest: Double, primaryJitter: Double = 0) -> (f572: Tally, f658: Tally) {
    var before = Tally(), after = Tally()
    for seed in 0..<3 {
        let meeting = simulate(seed: 0xF658_0000 + UInt64(seed) * 0x1_0001 + UInt64(jitter * 10),
                               jitter: jitter, sameSplit: sameSplit, shortest: shortest, primaryJitter: primaryJitter)
        // F572 offered Replace on every diverging row — the sheet's only condition.
        before += tally(meeting) { _ in true }
        after += tally(meeting) { $0.offersReplacement }
    }
    return (before, after)
}

extension Tally {
    static func += (total: inout Tally, part: Tally) {
        total.diverging += part.diverging
        total.offered += part.offered
        total.outside += part.outside
        total.dropped += part.dropped
    }
}

@Test("When both engines split at the same sentences, Replace offers only the line's own, and all of them (F658)")
func replaceOffersOnlyTheLinesOwnSentencesWhenTheSplitsAgree() {
    // The review's case: a short neighbour a few tenths of a second early was joined and written twice.
    for jitter in [0.2, 0.3, 0.5] {
        let (f572, f658) = run(jitter: jitter, sameSplit: true, shortest: 0.6)
        // The precondition: the simulation reaches the defect F572 left.
        if jitter >= 0.3 { #expect(f572.outside > 0, "±\(jitter) s: \(f572)") }
        #expect(f658.outside == 0, "±\(jitter) s: \(f658)")
        #expect(f658.dropped == 0, "±\(jitter) s: \(f658)")
        // And it still offers Replace on the rows it can: not a rule that never offers anything.
        #expect(Double(f658.offered) >= 0.85 * Double(f658.diverging), "±\(jitter) s: \(f658)")
    }
}

// When the engines group sentences independently, most diverging rows share a segment with another
// line — two lines the other engine heard as one, or one line it heard as two halves of two — and
// every one of those is shown without Replace. What is still offered is checked the same way.
//
// Here the shortest sentence is 1 s: `boundaryTolerance` plus the largest jitter, the shortest that
// timing alone can tell apart. A shorter sentence that the other engine joined to the neighbouring
// line's reading leaves too little evidence in either line, and is still offered now and then. A
// 10-seed run of this model during F658 (its log entry has the output) measured it: with
// 0.25–1.5 s short sentences, 100–214 of ~5,300–6,000 offered rows carried a neighbour's sentence
// and 84–102 left one out (F572: ~22,300 and ~1,100 of ~30,000 diverging rows); with 0.8–1.5 s,
// 3 and 1 at ±0.5 s and none below; with 1–1.5 s, none.
@Test("When the engines group sentences differently, Replace still offers only the line's own, and all of them (F658)")
func replaceOffersOnlyTheLinesOwnSentencesWhenTheSplitsDiffer() {
    for jitter in [0.2, 0.3, 0.5] {
        let (f572, f658) = run(jitter: jitter, sameSplit: false, shortest: 1.0)
        #expect(f572.outside > 0 && f572.dropped > 0, "±\(jitter) s: \(f572)")
        #expect(f658.outside == 0, "±\(jitter) s: \(f658)")
        #expect(f658.dropped == 0, "±\(jitter) s: \(f658)")
        #expect(Double(f658.offered) >= 0.15 * Double(f658.diverging), "±\(jitter) s: \(f658)")
    }
}

// F868: the sentences timing cannot tell from jitter — 0.25–1.5 s short sentences at ±0.5 s, F658's
// residue — are mostly caught by the words at the reading's edges (`readingCrossesALine`). A 10-seed run
// (F868's log entry) measured, independent groupings: F658 alone 199 offered rows carrying a
// neighbour's sentence and 79 leaving one out, F658 + F868 73 and 20, for 2 % fewer rows offered; same
// grouping 34 → 21 and 0 → 0. What is left is mostly the three sentences in ten the other engine heard
// differently ("v17"): their words match no one's. The bounds below are this seeded run's (3 seeds:
// 10/0 same, 32/6 independent) with a little room, and sit below F658's alone.
@Test("A short sentence joined across lines is caught by its words where timing cannot see it (F868)")
func edgeWordsCatchShortSentencesJoinedAcrossLines() {
    let (_, same) = run(jitter: 0.5, sameSplit: true, shortest: 0.25)
    #expect(same.outside <= 12 && same.dropped == 0, "\(same)")
    #expect(Double(same.offered) >= 0.85 * Double(same.diverging), "\(same)")
    let (_, independent) = run(jitter: 0.5, sameSplit: false, shortest: 0.25)
    #expect(independent.outside <= 36 && independent.dropped <= 8, "\(independent)")
    #expect(Double(independent.offered) >= 0.15 * Double(independent.diverging), "\(independent)")
}

// F872: with BOTH engines' boundaries moved by up to ±0.5 s — this transcript's too, which the model
// above pins to the sentences — on sentences of at least 1 s. The lane R review measured F658 offering
// ~50 % (same grouping) / ~9 % (independent) of diverging rows here and 3 of 827 offered rows dropping
// words. A 10-seed run (F872's log entry): F658 alone 4 rows outside and 2 dropping of 2,863 offered at
// ±0.5 s independent; with F868, 1 and 0. The offer rate is the cost of two engines disagreeing by up to
// a second where the tolerance allows half: 48 % and 9.5 %, measured, and asserted not to fall further.
@Test("With both engines' boundaries off by up to half a second, Replace still offers only a line's own (F872)")
func bothEnginesJitteredStillOfferOnlyTheLinesOwn() {
    let (_, same) = run(jitter: 0.5, sameSplit: true, shortest: 1.0, primaryJitter: 0.5)
    #expect(same.outside == 0 && same.dropped == 0, "\(same)")
    #expect(Double(same.offered) >= 0.45 * Double(same.diverging), "\(same)")
    let (_, independent) = run(jitter: 0.5, sameSplit: false, shortest: 1.0, primaryJitter: 0.5)
    #expect(independent.outside + independent.dropped <= 1, "\(independent)")
    #expect(Double(independent.offered) >= 0.08 * Double(independent.diverging), "\(independent)")
}

// MARK: - The same meetings in real words (review of F868)
//
// Every sentence above is one unique token, so no two sentences share a word and F868's edge check can
// never match by coincidence. Real speech can: line edges are dominated by a few words ("so", "and",
// "I", "yeah", "okay"; 好的, 对). `realWords` writes the SAME meeting — the same lines, segments,
// timings, misses and mishearings — in real English or Chinese: a short sentence (≤ 1.5 s) is an
// interjection, a long one an opener + a clause + a closer drawn from meeting speech, and a sentence
// heard differently has one word (one character in Chinese) changed. Since only the words differ, a
// row the token meeting offers correctly and the real one withholds is withheld by coincidence: that
// is F868's cost on real words.

private enum Speech { case english, chinese }

private let englishShort = ["Yeah.", "Okay.", "Right.", "Sure.", "Got it.", "Okay, sure.", "Nice.", "Agreed.",
                            "Thank you.", "Exactly.", "So, yes.", "I think so.", "No.", "Yes.", "Mm-hmm.",
                            "That works.", "And then?", "So?", "Me too.", "Fair enough."]
private let englishOpeners = ["", "So ", "And ", "I think ", "But ", "Okay, so ", "Then ", "Yeah, ", "The thing is, ",
                              "And so ", "I mean ", "So yeah, "]
private let englishClauses = [
    "the release is moving to next week", "we should ship the installer on Friday", "the build passed all of its checks",
    "Maria will review the export", "the survey had about forty answers", "search in the library is still too slow",
    "we need six new microphones", "the budget was approved this morning", "I can take the PDF export",
    "the timestamps are off by a second", "nobody has looked at the crash report", "it works on my machine",
    "we can talk about it offline", "the customer asked for a refund", "I'll send the notes after the call",
    "the meeting ran over again", "let's move on to the next item", "the numbers look better than last month",
    "we still have two open bugs", "the design review is on Thursday", "that is a good question",
    "I'm not sure about the date", "we decided to keep the old layout", "the server was down for an hour",
    "the new hire starts on Monday", "we should write that down", "the demo went well", "I agree with that",
    "it depends on the vendor", "there is one more thing",
]
private let englishClosers = ["", " too", " then", " as well", " for now", " I guess", " right", " so", " I think", " again", " okay"]
private let chineseShort = ["好的。", "对。", "嗯。", "是的。", "可以。", "没问题。", "行。", "明白。", "好。", "对对对。"]
private let chineseOpeners = ["", "那", "所以", "我觉得", "然后", "但是", "好的，", "对，"]
private let chineseClauses = [
    "我们下周发布新版本", "安装程序还需要再看一遍", "这个问题我们线下再聊", "客户要求退款", "预算今天上午批下来了",
    "我来负责导出功能", "搜索还是太慢了", "服务器宕机了一个小时", "新同事周一入职", "设计评审在周四",
    "我们还有两个问题没解决", "演示很顺利", "数字比上个月好", "这个时间我不太确定", "我会在会后发会议纪要",
]
private let chineseClosers = ["", "吧", "了", "啊", "对吧", "就这样"]

/// Sentence `id` in real words: an interjection when it is short, else opener + clause + closer.
private func realSentence(_ id: Int, seconds: Double, _ speech: Speech) -> String {
    var rng = SplitMix(state: 0xF868_0000_0000 ^ UInt64(id))
    func pick(_ list: [String]) -> String { list[Int(rng.next() % UInt64(list.count))] }
    switch speech {
    case .english:
        if seconds <= 1.5 { return pick(englishShort) }
        let sentence = pick(englishOpeners) + pick(englishClauses) + pick(englishClosers) + "."
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    case .chinese:
        if seconds <= 1.5 { return pick(chineseShort) }
        return pick(chineseOpeners) + pick(chineseClauses) + pick(chineseClosers) + "。"
    }
}

/// `text` as the other engine heard it differently: one word (one character in Chinese) changed.
private func misheard(_ text: String, id: Int, _ speech: Speech) -> String {
    var rng = SplitMix(state: 0x00F8_68F8_6800 ^ UInt64(id))
    switch speech {
    case .english:
        var words = text.split(separator: " ").map(String.init)
        let index = Int(rng.next() % UInt64(words.count))
        let word = words[index]
        let letters = word.filter(\.isLetter)
        words[index] = letters.count > 3 ? word.replacingOccurrences(of: String(letters.prefix(3)), with: String(letters.prefix(2)) + "e")
                                         : "the" + word
        return words.joined(separator: " ")
    case .chinese:
        var characters = Array(text)
        let ideographs = characters.indices.filter { characters[$0].unicodeScalars.allSatisfy { ActionItemEvidence.isCJKIdeograph($0) } }
        guard !ideographs.isEmpty else { return text + "嗯" }
        characters[ideographs[Int(rng.next() % UInt64(ideographs.count))]] = "某"
        return String(characters)
    }
}

/// `meeting` with every sentence written in real words, everything else unchanged.
private func realWords(_ meeting: Meeting, _ speech: Speech) -> (primary: [TranscriptSegment], secondary: [TranscriptSegment]) {
    let separator = speech == .english ? " " : ""
    func line(_ sentences: [Int], heardBy other: Bool) -> String {
        sentences.map { id in
            let text = realSentence(id, seconds: meeting.seconds[id], speech)
            return other && meeting.heardDifferently.contains(id) ? misheard(text, id: id, speech) : text
        }.joined(separator: separator)
    }
    let primary = zip(meeting.primary, meeting.lineSentences).map { segment, sentences in
        TranscriptSegment(speaker: nil, start: segment.start, end: segment.end, text: line(sentences, heardBy: false))
    }
    let secondary = zip(meeting.secondary, meeting.secondarySentences).map { segment, sentences in
        TranscriptSegment(speaker: nil, start: segment.start, end: segment.end, text: line(sentences, heardBy: true))
    }
    return (primary, secondary)
}

private struct WordCost: CustomStringConvertible {
    /// Rows diverging in both, offered in the token meeting and correct there (only the line's own
    /// sentences, all of those heard).
    var correctOffers = 0
    /// Of those, withheld in real words: F868 matching a common word by coincidence.
    var withheldByCoincidence = 0
    /// Rows offered in real words that carry a neighbour's sentence or leave one of the line's out.
    var wrongRealOffers = 0
    var description: String {
        let rate = correctOffers == 0 ? 0 : 100 * Double(withheldByCoincidence) / Double(correctOffers)
        return "correctOffers=\(correctOffers) withheldByCoincidence=\(withheldByCoincidence) (\(String(format: "%.2f", rate)) %) wrongRealOffers=\(wrongRealOffers)"
    }
}

private func wordCost(_ speech: Speech, sameSplit: Bool, shortest: Double, jitter: Double = 0.5) -> WordCost {
    var cost = WordCost()
    for seed in 0..<3 {
        let meeting = simulate(seed: 0xF868_F868 + UInt64(seed) * 0x1_0001, jitter: jitter, sameSplit: sameSplit,
                               sentences: 3_000, shortest: shortest)
        let tokenRows = TranscriptComparison.compare(meeting.primary, meeting.secondary)
        let real = realWords(meeting, speech)
        let realRows = TranscriptComparison.compare(real.primary, real.secondary)
        for line in tokenRows.indices where tokenRows[line].kind == .diverge && realRows[line].kind == .diverge {
            let own = Set(meeting.lineSentences[line])
            let offered = Set(sentences(in: tokenRows[line].secondaryText ?? ""))
            let correct = offered.isSubset(of: own) && own.intersection(meeting.heard).isSubset(of: offered)
            if tokenRows[line].offersReplacement, correct {
                cost.correctOffers += 1
                if !realRows[line].offersReplacement { cost.withheldByCoincidence += 1 }
            }
            if realRows[line].offersReplacement, !correct { cost.wrongRealOffers += 1 }
        }
    }
    return cost
}

// Measured (F868 round 2's log entry has every configuration, and the variants): in English, 1.2–1.7 % of
// the rows the token meeting offers correctly are withheld by a coincidental match, and the check removes
// 35 of the 42 wrong offers timing alone makes (independent groupings, 0.25 s sentences). Requiring two
// matching words would halve the cost (0.4–0.9 %) and give back most of that protection (28 wrong
// offers): the one-word match is the point, because the sentences it is for are one word — "Yeah.",
// "Okay.", "No." — so it stays. Chinese is F868's known gap (a run is one word) and changes nothing
// either way. The bounds hold the English cost and protection near what was measured.
@Test("On real English, F868's edge check withholds under 2.5 % of correct Replaces and stops most wrong ones (F868)")
func edgeWordsCostLittleOnRealEnglish() {
    let independent = wordCost(.english, sameSplit: false, shortest: 0.25)
    #expect(independent.correctOffers > 500, "\(independent)")
    #expect(Double(independent.withheldByCoincidence) <= 0.025 * Double(independent.correctOffers), "\(independent)")
    #expect(independent.wrongRealOffers <= 10, "timing alone makes 42 here: \(independent)")
    let same = wordCost(.english, sameSplit: true, shortest: 0.6)
    #expect(Double(same.withheldByCoincidence) <= 0.025 * Double(same.correctOffers), "\(same)")
    #expect(same.wrongRealOffers == 0, "\(same)")
}
