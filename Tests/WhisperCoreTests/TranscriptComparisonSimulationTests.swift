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
// words even for 1 s sentences, and the offer rate falling to ~50 % / ~9 %. Widening the model, and
// measuring two real engines on one clip, is F872.

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
}

private func simulate(seed: UInt64, jitter: Double, sameSplit: Bool, sentences count: Int = 6_000,
                      shortest: Double = 0.6) -> Meeting {
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
    for group in primaryGroups {
        meeting.primary.append(TranscriptSegment(
            speaker: nil, start: spans[group.first!].start, end: spans[group.last!].end,
            text: group.map { "w\($0)." }.joined(separator: " ")
        ))
        meeting.lineSentences.append(group)
    }
    for group in secondaryGroups {
        let said = group.filter { _ in !rng.chance(1.0 / 30) }
        let words = said.map { rng.chance(0.3) ? "v\($0)." : "w\($0)." }
        guard !said.isEmpty else { continue }
        meeting.heard.formUnion(said)
        let start = spans[group.first!].start + rng.uniform(-jitter...jitter)
        let end = max(start + 0.05, spans[group.last!].end + rng.uniform(-jitter...jitter))
        meeting.secondary.append(TranscriptSegment(speaker: nil, start: start, end: end, text: words.joined(separator: " ")))
    }
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
private func run(jitter: Double, sameSplit: Bool, shortest: Double) -> (f572: Tally, f658: Tally) {
    var before = Tally(), after = Tally()
    for seed in 0..<3 {
        let meeting = simulate(seed: 0xF658_0000 + UInt64(seed) * 0x1_0001 + UInt64(jitter * 10),
                               jitter: jitter, sameSplit: sameSplit, shortest: shortest)
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
