import Foundation

/// A proposed, user-reviewable spelling correction toward a vocabulary term (F65).
public struct GlossaryCorrection: Sendable, Equatable {
    public let segmentIndex: Int
    public let from: String
    public let to: String
    /// Where in its segment's text the occurrence this row changes starts, in `Character`s — set
    /// only where that is not the first genuine occurrence of `from`, which is where every row
    /// without one is applied (F950). Apply Replacement Rules sets it for a sentence's first word
    /// that follows the same word mid-sentence ("Zoë and Jon. Jon left." with "jon → jonathan"):
    /// a row naming only "Jon" would change the name. Correct Toward Vocabulary sets it for a Latin
    /// window whose text first occurs earlier as a whole word of a worse window ("the Kestrol/Falcon
    /// build and the Kestrol release", F914). Never persisted: a row lives for one review.
    public let characterOffset: Int?
    /// The text of the row's line when it was proposed (F971), or nil for a row that names none.
    /// `GlossaryCorrector.apply` skips a row whose line no longer reads so, and the review sheet
    /// draws the row's sentence on it. The app sets it on every row it hands a review sheet
    /// (`GlossaryCorrector.proposing(_:on:)`): a line can change between proposing and Apply (a
    /// second window on the meeting, or the lines replaced under an open sheet), and a row resolved
    /// on the changed line could land on a word nobody reviewed — another occurrence now at its
    /// `characterOffset`, or the first occurrence of its text.
    public let proposedLine: String?

    public init(segmentIndex: Int, from: String, to: String, characterOffset: Int? = nil, proposedLine: String? = nil) {
        self.segmentIndex = segmentIndex
        self.from = from
        self.to = to
        self.characterOffset = characterOffset
        self.proposedLine = proposedLine
    }
}

/// Pure near-miss matching of transcript spans against the user's vocabulary. For each term it finds
/// the best window in a segment whose normalized form is similar enough (longest-common-subsequence
/// ratio) to the term, skipping exact matches and too-distant/cross-script candidates. The user
/// reviews every proposal before it applies; nothing auto-applies (F65).
///
/// **Two kinds of window (F536).** A Latin term is compared with windows of one to three
/// whitespace-separated words — as in F65, and pinned against a copy of the old code by
/// `GlossaryCorrectorGoldenTests`, amended only where a later ticket changed the answer on purpose:
/// a proposal no longer takes the punctuation stuck to its outer words with it (F819, "Kestrol," is
/// proposed as "Kestrol"), a term equal to a window of several words is already present (F820,
/// "Priya Raman said" proposes nothing for "Priya Raman"), a row `apply` would leave unchanged
/// is not proposed at all (F820's review), a term of three or more words is compared with
/// windows up to one more than its own length and is present only across no more words than its
/// own (F940, F968), a proposal names the window's text as it stands and
/// is applied to that window (F914, `characterOffset`), a dash ends a word as a space does
/// while a possessive 's is outside the window (F915), and windows of more than three words are
/// compared only where the line holds at least half the term's words (F972). A term containing
/// Chinese is compared
/// with windows of exactly its own length, slid character by character along each run of letters
/// and digits: Chinese
/// has no spaces, so the old whitespace split made a whole sentence one "word" — a short segment was
/// proposed to be replaced wholesale ("对，张经里" → "张经理", deleting "对，") and a mishearing
/// inside an ordinary sentence was never found. A term already present in the segment is correct and
/// proposes nothing. A window must match more than half the term's characters, position for
/// position — one of two for a two-character term, since F817 (`enoughInPlace`) — and every
/// character it gets wrong must sound like the term's, or nearly, by the accent confusions
/// `MandarinSound` folds (zh/z, sh/s/x, n/l, in/ing…, F916), though a near sound never stands
/// for a term's leading surname (程经理 is not 陈经理), no numeral is changed (四月 is not 十月)
/// and no window that is itself a term is
/// proposed (公司 is not 公式 when both are listed): matching two of three
/// characters in place also fits 王经理 for 张经理 and 数据集 for 数据库, which the review of F536
/// found pre-ticked in seven of eight ordinary sentences. A homophone can still be a different real
/// word or another person's name (公事 for 公式, 张薇 for 张伟), which is why a Chinese near-miss
/// arrives unticked and needs its own tick (`ProposalReview`) — and a two-character term that is a
/// person's name, as the caller's segmenter tells one (`ChinesePersonName`, F921), gets no
/// sound-alike row at all. A Chinese window is only proposed where
/// `GlossaryCorrector.apply` would apply it — `ReplacementBoundary` with the caller's
/// `CJKWordEvidence` (F594) — so a window cutting
/// through a word is not offered. A Latin term's windows split a token where Latin meets Chinese
/// ("这个Kubernets集群"), so the proposal replaces "Kubernets", not the Chinese on either side; text
/// without Chinese splits as it did.
///
/// **Cost (F536).** This ran segment × term × window with an O(n·m) LCS and re-normalized every term
/// for every segment, on the main actor — the round-2 sweep measured about 136 s for one meeting at
/// the 5,000-term cap. Each term is now prepared once, a Latin window whose length alone rules out
/// the threshold (or cannot beat the best found so far) is skipped before any LCS, and segments run
/// in parallel with progress and cancellation (`corrections(vocabulary:segments:evidence:
/// isCancelled:progress:)`). Measured at -O in a scratch package outside the repository, on a
/// 700-segment synthetic meeting against 5,000 terms: 78.9 s before, 1.2 s after, with the same
/// 167,128 English proposals. What the repository pins is smaller: `GlossaryCorrectorGoldenTests`
/// compares 80 terms × 60 segments against the old code (as amended, above). F940's longer windows,
/// measured the same way on this Mac (best of three, 700 segments, 5,000 terms): 3.48 s before and
/// 3.57 s after with no term over three words; 3.33 s and 4.36 s with 353 terms of four to six.
/// F972's gate, measured the same way with other work sharing the Mac: 5.18 s → 3.32 s with those
/// 353 terms (their rows 2,696 → 16, the chance matches gone and the probe's 16 real mishearings
/// kept); 4.71 s → 3.45 s with 50 phrases of 10–20 words on 10–21-word lines; 27.58 s → 13.62 s on
/// 40–80-word lines (`.claude/wave7/gates/F972-cost-{before,after}.log`).
public enum GlossaryCorrector {
    static let similarityThreshold = 0.5
    static let maxWindow = 3

    public static func corrections(
        vocabulary: [String],
        segments: [TranscriptSegment],
        evidence: CJKWordEvidence = .none
    ) -> [GlossaryCorrection] {
        corrections(
            vocabulary: vocabulary, segments: segments, evidence: evidence,
            isCancelled: { false }, progress: { _ in }
        ) ?? []
    }

    /// The same pass, reporting the fraction of segments done and stopping early once `isCancelled`
    /// returns true — then the result is nil (F536). Both closures are called from worker threads.
    /// Proposals come back in segment order, then vocabulary order, as they always have.
    public static func corrections(
        vocabulary: [String],
        segments: [TranscriptSegment],
        evidence: CJKWordEvidence,
        isCancelled: @escaping @Sendable () -> Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) -> [GlossaryCorrection]? {
        let prepared = PreparedVocabulary(vocabulary, knownTerms: evidence.knownTerms, segmenter: evidence.segmenter)
        let tracker = ProgressTracker(total: segments.count, report: progress)
        var perSegment = [[GlossaryCorrection]](repeating: [], count: segments.count)
        perSegment.withUnsafeMutableBufferPointer { slots in
            // Each iteration writes only its own slot, so the buffer needs no lock.
            let slots = slots
            DispatchQueue.concurrentPerform(iterations: segments.count) { index in
                guard !isCancelled() else { return }
                slots[index] = corrections(
                    in: segments[index].text, segmentIndex: index, prepared: prepared, evidence: evidence
                )
                tracker.finishedOne()
            }
        }
        guard !isCancelled() else { return nil }
        return perSegment.flatMap { $0 }
    }

    // MARK: - One segment

    private static func corrections(
        in text: String, segmentIndex: Int, prepared: PreparedVocabulary, evidence: CJKWordEvidence
    ) -> [GlossaryCorrection] {
        let tokens = latinTokens(of: text)
        // F65's own guard: a segment with no words proposes nothing.
        guard !tokens.isEmpty else { return [] }
        let latin = LatinWindows(tokens: tokens, in: text, table: prepared.table)
        let chinese = prepared.hasCJKTerms ? CJKRuns(text: text, table: prepared.table) : nil
        let segmented = SegmentedText(text, segmenter: evidence.segmenter)
        // Only a known term present in this segment can enclose one of its windows, so the F594
        // known-term check is given those, worked out the first time a window needs them, rather than
        // the whole vocabulary once per window.
        var enclosing: CJKWordEvidence?
        let segmentEvidence = { () -> CJKWordEvidence in
            if let enclosing { return enclosing }
            let present = CJKWordEvidence(
                segmenter: evidence.segmenter, knownTerms: prepared.knownCJKTerms.filter { text.contains($0) }
            )
            enclosing = present
            return present
        }
        var scratch = LCSScratch()
        // Character readings for the homophone check, per segment so no worker shares it.
        var sounds: [Character: String] = [:]
        var results: [GlossaryCorrection] = []
        for term in prepared.terms where !term.ids.isEmpty {
            if term.isCJK {
                // A person's name gets no sound-alike row at all (F921): the text cannot tell a
                // mishearing of 张伟 from the person 张薇, and renaming a person is the worse error.
                guard !term.isPersonName, let chinese,
                      let phrase = bestCJKWindow(for: term, in: chinese, text: text, segmented: segmented,
                                                 otherTerms: prepared.cjkTermIDs,
                                                 evidence: segmentEvidence, sounds: &sounds) else { continue }
                results.append(GlossaryCorrection(segmentIndex: segmentIndex, from: phrase, to: term.term))
            } else if let placed = bestLatinWindow(for: term, in: latin, text: text, scratch: &scratch) {
                results.append(GlossaryCorrection(
                    segmentIndex: segmentIndex, from: placed.phrase, to: term.term, characterOffset: placed.offset
                ))
            }
        }
        return results
    }

    /// A Latin proposal: its text as it stands in the segment, and where `apply` is to change it
    /// (F914) — nil where that is the first genuine occurrence of the text, as `apply` resolves a
    /// row without one (F950).
    private struct Placement {
        let phrase: String
        let offset: Int?
    }

    /// F65's search, which picks the same window for text without Chinese: the first 1–3-token
    /// window (1–(n+1) for a term of n ≥ 3 words, F940 and F968, below) with the highest ratio at
    /// or above the threshold, unless the
    /// term already stands as a window — one token or, since F820, several: F65 asked only whether
    /// it was one token, so a correct "Priya Raman said" scored 10/14 against "Priya Raman" and was
    /// proposed as it, deleting "said". The phrase returned is the window's text as it stands in
    /// the segment (F914) without the punctuation stuck to its outer words, less what the term's
    /// own spelling begins or ends with (F819), and the row is applied to that window — see
    /// `placedPhrase`.
    ///
    /// And nothing is proposed that `apply` would leave unchanged (F820, the Wave 5 review's T10):
    /// a row whose text lies inside the correct term changes nothing — `apply` never changes text
    /// inside the term. (Words joined across a tab or a double space were proposed with one space,
    /// which `apply` never found, until F914 made the phrase the text as it stands.)
    ///
    /// **A term of three or more words is compared with windows up to one more than its own length
    /// (F940, F968)**; every other term with windows of up to three words, as F65 compared every
    /// term. With three, the best window for a mishearing of a longer term was part of it, and
    /// applying its row wrote the whole term beside the rest: "the Bank of New Yolk said yes" became
    /// "the Bank of New York Yolk said yes", and "Bank of New York Melon" "Bank of Bank of New York
    /// Mellon" (F940). With exactly its own length, a mishearing that split one of the term's words
    /// was compared with too short a window and left the fragment behind: "the Bank of New Yor k"
    /// became "the Bank of New York k" (F968).
    ///
    /// **A term is present where it equals a window of no more words than its own (F820, F968):**
    /// "Priya Raman said", "Bank⟨TAB⟩of New York". Equal across *more* words it is that term with a
    /// word split in two — "Kuber netes", "Priya Ram an" — a mishearing like any other, and the
    /// best there is (F968; F820 counted any equal window as the term present, so "Kuber netes"
    /// was never proposed).
    ///
    /// **Windows of more than three words are compared, and built, only where the line holds at
    /// least half the term's words (F972)** — one for a three-word term, two for four or five, ten
    /// for twenty — as whole normalized words. A term of four or more words, which has no window
    /// of its own length elsewhere, is then not compared with such a line at all; a three-word
    /// term keeps F65's windows of up to three there. A mishearing keeps most of a phrase's words,
    /// so the gate costs a row only for a phrase misheard in more than half its words; what it
    /// saves is building every line's windows up to the longest phrase in the vocabulary (the Wave
    /// 6 review measured +22% on ordinary lines and +78% on long ones with 50 phrases of 10–20
    /// words), and the chance matches a long window makes at the 0.5 threshold.
    private static func bestLatinWindow(
        for term: PreparedTerm, in windows: LatinWindows, text: String, scratch: inout LCSScratch
    ) -> Placement? {
        let allowance: Int
        if term.wordCount + 1 <= maxWindow {
            allowance = maxWindow
        } else if windows.holds(atLeast: max(1, term.wordCount / 2), of: term.words) {
            allowance = term.wordCount + 1
        } else if term.wordCount <= maxWindow {
            allowance = maxWindow
        } else {
            return nil
        }
        windows.extend(to: allowance)
        if let smallest = windows.smallestWindowSpelling[term.normalized], smallest <= term.wordCount { return nil }
        var best: (similarity: Double, window: LatinWindows.Window)?
        // A window equal to the term is scored like any other: it has more words than the term, or
        // the term would be present (above), and the LCS ratio gives it 1.
        for window in windows.all[..<windows.end(ofSize: allowance)]
        where !window.containsCJK && !window.ids.isEmpty {
            let longer = max(window.ids.count, term.ids.count)
            // The LCS is at most the shorter length, so this ratio bounds the score: skip a window
            // that cannot reach the threshold, or cannot beat the best already found (F536).
            let bound = Double(min(window.ids.count, term.ids.count)) / Double(longer)
            guard bound >= similarityThreshold, bound > (best?.similarity ?? 0) else { continue }
            let score = Double(scratch.lcs(window.ids, term.ids)) / Double(longer)
            if score >= similarityThreshold, score > (best?.similarity ?? 0) {
                best = (score, window)
            }
        }
        guard let window = best?.window else { return nil }
        return placedPhrase(window, term: term.term, in: text)
    }

    /// The window's phrase trimmed for `term` (F819), placed where it stands (F914): the row is
    /// applied to the window that was scored, never to an earlier occurrence of its text. `apply`
    /// changes the first genuine occurrence of a row's text unless the row names its place
    /// (`characterOffset`, F950), so the place is named wherever the window is not that first
    /// occurrence — in "the Kestrol/Falcon build and the Kestrol." the window is "Kestrol." and
    /// "Kestrol" first occurs, a whole word to `apply` (a slash is a word edge), in "Kestrol/Falcon"
    /// (until F914 the untrimmed "Kestrol." was proposed instead, and the full stop went with it;
    /// glued by a hyphen the first "Kestrol" is a window of its own since F915, and is the one
    /// proposed). A trimmed phrase that is
    /// no genuine occurrence where it stands ("Kestrol" inside "Kestrol_": an underscore is part of
    /// the word) gives way to the untrimmed one, as before; and a window that is no genuine
    /// occurrence even untrimmed — inside the correct term, so covered by it — is no row (F820).
    private static func placedPhrase(_ window: LatinWindows.Window, term: String, in text: String) -> Placement? {
        let segmented = SegmentedText(text, segmenter: nil)
        func placement(of phrase: String, at range: Range<String.Index>) -> Placement? {
            let ranges = ReplacementBoundary(heard: phrase, notCoveredBy: term).genuineRanges(in: segmented)
            guard let position = ranges.firstIndex(of: range) else { return nil }
            return Placement(phrase: phrase, offset: position == 0 ? nil : text.distance(from: text.startIndex, to: range.lowerBound))
        }
        var kept = trimmedBounds(of: window.phrase, keepingTheEdgesOf: term)
        // A possessive 's at the end is outside the window too (F915), unless the term's own
        // spelling ends so (McDonald's): "Kestrel's" normalized to "kestrels", so the term was not
        // present, the window scored 7/8 and the row deleted the 's. With the 's off, a correct
        // term is covered by itself and no row is made — never the untrimmed window back.
        let characters = Array(window.phrase)
        let possessive = kept.count > 2 && characters[kept.upperBound - 1].lowercased() == "s"
            && apostrophes.contains(characters[kept.upperBound - 2]) && !endsWithAPossessive(term)
        if possessive { kept = kept.lowerBound..<(kept.upperBound - 2) }
        if kept != 0..<characters.count {
            let start = text.index(window.range.lowerBound, offsetBy: kept.lowerBound)
            let end = text.index(window.range.lowerBound, offsetBy: kept.upperBound)
            if let placed = placement(of: String(text[start..<end]), at: start..<end) { return placed }
            if possessive { return nil }
        }
        return placement(of: window.phrase, at: window.range)
    }

    private static let apostrophes: Set<Character> = ["'", "\u{2019}"]

    private static func endsWithAPossessive(_ term: String) -> Bool {
        let characters = Array(term)
        return characters.count > 2 && characters[characters.count - 1].lowercased() == "s"
            && apostrophes.contains(characters[characters.count - 2])
    }

    /// The best window of exactly the term's length in any run of letters and digits (F536), or nil
    /// when the term is already present, no window matches enough of its characters position for
    /// position (`enoughInPlace`) with every other character a homophone, or the only such windows
    /// cut through a word.
    ///
    /// Position for position rather than an LCS: a Chinese mishearing substitutes a character for a
    /// homophone and keeps the length (张经理 → 张经里), and an LCS also credits the window one
    /// character to the left — 请张经 shares 张经 with 张经理 as a subsequence, and comes first.
    ///
    /// A window that is itself a vocabulary term is never proposed (F916, F921): the user listed
    /// that spelling, so it is no mishearing of another term however alike the two sound — 公司 and
    /// 公式 both listed gave a row 公司 → 公式 on every line that said 公司, and back.
    private static func bestCJKWindow(
        for term: PreparedTerm, in runs: CJKRuns, text: String, segmented: SegmentedText,
        otherTerms: Set<[Int32]>, evidence: () -> CJKWordEvidence, sounds: inout [Character: String]
    ) -> String? {
        let length = term.ids.count
        // Cheap upper bound first: every matched character must occur in the segment somewhere.
        guard enoughInPlace(term.ids.count(where: runs.characterSet.contains), of: length) else { return nil }
        if runs.contains(term.ids) { return nil }
        var best: (score: Int, phrase: String)?
        for run in runs.runs where run.ids.count >= length {
            for start in 0...(run.ids.count - length) {
                var common = 0
                for offset in 0..<length where run.ids[start + offset] == term.ids[offset] {
                    common += 1
                }
                // Enough in place, and better than the best genuine window so far.
                guard enoughInPlace(common, of: length), common > (best?.score ?? 0) else { continue }
                // And every character it gets wrong sounds like the one it should be: 张经里 for
                // 张经理, not 王经理 — a different person who matches just as many characters.
                let soundsAlike = (0..<length).allSatisfy { offset in
                    run.ids[start + offset] == term.ids[offset]
                        || mayStandIn(
                            text[run.indices[start + offset]], for: term.characters[offset],
                            leading: offset == 0, sounds: &sounds
                        )
                }
                guard soundsAlike, !otherTerms.contains(Array(run.ids[start..<(start + length)])) else { continue }
                let range = run.indices[start]..<run.end(of: start + length - 1, in: text)
                let phrase = String(text[range])
                let boundary = ReplacementBoundary(heard: phrase, notCoveredBy: term.term, evidence: evidence())
                // Proposed only where `apply` would put it: the first genuine occurrence of this
                // text must be this window, so the proposal and its application agree (F444, F594).
                guard boundary.firstRange(in: segmented) == range else { continue }
                best = (common, phrase)
            }
        }
        return best?.phrase
    }

    /// Whether `heard`, in a window, may be a mishearing of the term's `meant`: it sounds like it
    /// (`MandarinSound`), it is no numeral, and, where the sound is only near rather than the same,
    /// it is not the term's first character with a surname on either side (F916).
    ///
    /// A numeral the recognizer wrote is kept, however alike it sounds: 四 (si) near 十 and 市 (shi)
    /// made 我们四月见 October and 四场比赛 a market, and an exact homophone is no safer (十间 for
    /// 时间, both shi). A word heard for a numeral of the term's (周无 for 周五) is still proposed.
    ///
    /// 程经理 is not 陈经理, nor is 宁总 林总: an accent's near sound is as likely another person as a
    /// mishearing, and renaming a person is the worse error (F921). Either side, since the list is
    /// `ChinesePersonName`'s hundred: 宁 is not on it, 林 is.
    private static func mayStandIn(
        _ heard: Character, for meant: Character, leading: Bool, sounds: inout [Character: String]
    ) -> Bool {
        guard !chineseNumerals.contains(heard),
              MandarinSound.isHomophone(heard, of: meant, cache: &sounds) else { return false }
        if leading, ChinesePersonName.surnames.contains(heard) || ChinesePersonName.surnames.contains(meant),
           !MandarinSound.isExactHomophone(heard, of: meant, cache: &sounds) {
            return false
        }
        return true
    }

    /// The characters that write a number, everyday and financial forms: a sound-alike row never
    /// changes one (F916).
    private static let chineseNumerals: Set<Character> = Set("〇零一二两三四五六七八九十百千万亿壹贰叁肆伍陆柒捌玖拾佰仟")

    /// Whether `common` characters in place are enough for a Chinese term of `length` characters:
    /// more than half, as F536 asked, except one in two for a two-character term (F817).
    ///
    /// More than half kept every two-character term from ever being proposed — 会意 for 会议, 周无
    /// for 周五: one substitution is half the word. F536 set it before the homophone rule existed, to
    /// stop 计算 being proposed for 预算, and the homophone rule now does that (ji is not yu). One in
    /// two is still required, so a word that only sounds like the term — 攻势 for 公式, gong shi
    /// both — is not proposed. F817's first round lowered every even length to half, and the Wave 5
    /// review measured what that did to four-character terms: two new right rows (会意记要, 书局分析)
    /// and three new wrong ones from two patterns (时常分析 for 市场分析, twice; 项目精力 for 项目经理 —
    /// other words that sound alike), so a longer term is back to more than half.
    static func enoughInPlace(_ common: Int, of length: Int) -> Bool {
        length == 2 ? common >= 1 : common * 2 > length
    }

    // MARK: - Preparation (F536: once per pass, not once per segment × term)

    /// A Latin term's windows are whitespace-separated words, as before F536, further split where a
    /// Chinese character meets a non-Chinese one, so code-switched text written without spaces
    /// ("这个Kubernets集群") yields "Kubernets" rather than the whole run.
    private struct Token {
        let text: String
        /// Where the token stands in its segment's text (F914): a window's phrase is the text from
        /// its first token's start to its last token's end, separators and all.
        let range: Range<String.Index>
        let isCJK: Bool
    }

    /// A Latin term's words, normalized, split as a segment's are, so a term and a window of it
    /// count alike (a word of punctuation alone normalizes to "").
    static func latinWords(of term: String) -> [String] {
        latinTokens(of: term).map { normalize($0.text) }
    }

    /// A hyphen, an en dash or an em dash ends a word as a space does (F915): "Kestrol—the" was one
    /// window, so its row deleted "—the", and "Kestrol-ish" scored as one word of ten letters. A
    /// window of several words keeps the dash between them in its phrase (F914), so "why-fi" is
    /// still proposed whole for "Wi-Fi".
    private static let dashes: Set<Character> = ["-", "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}"]

    private static func latinTokens(of text: String) -> [Token] {
        var tokens: [Token] = []
        var start: String.Index?
        var pieceIsCJK = false
        func close(at end: String.Index) {
            if let begin = start { tokens.append(Token(text: String(text[begin..<end]), range: begin..<end, isCJK: pieceIsCJK)) }
            start = nil
        }
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == " " || character == "\n" || character == "\t" || dashes.contains(character) {
                close(at: index)
            } else {
                let isCJK = ReplacementBoundary.hasCJK(String(character))
                if start != nil, isCJK != pieceIsCJK { close(at: index) }
                if start == nil { start = index }
                pieceIsCJK = isCJK
            }
            index = text.index(after: index)
        }
        close(at: text.endIndex)
        return tokens
    }

    /// One segment's Latin windows. A class, not a struct: it grows on demand (F972) within one
    /// segment's pass, which is one worker's work and shares it with no other thread.
    private final class LatinWindows {
        struct Window {
            let ids: [Int32]
            /// The window's text as it stands in the segment, punctuation and separators and all
            /// (F914; until then the words joined with one space, as F65 joined them); trimmed for
            /// a term only once it is the best window for that term (F819, `placedPhrase`).
            let phrase: String
            let range: Range<String.Index>
            let containsCJK: Bool
        }

        /// Every built window's normalized text, with the fewest tokens it is spelled across — a
        /// term equal to one of no more tokens than its own words is already in the segment (F820,
        /// F968).
        private(set) var smallestWindowSpelling: [String: Int] = [:]
        /// In F65's order: every one-token window, then every two-token window, then three — and
        /// on, size by size, as far as a term has asked (F940, F968, F972).
        private(set) var all: [Window] = []
        /// `ends[size]` is where the windows of `size` tokens end in `all`.
        private var ends = [0]
        private let tokens: [Token]
        private let normalized: [String]
        private let text: String
        private let table: CharacterTable
        /// The segment's normalized words, for the F972 gate.
        private let words: Set<String>

        init(tokens: [Token], in text: String, table: CharacterTable) {
            self.tokens = tokens
            self.text = text
            self.table = table
            normalized = tokens.map { GlossaryCorrector.normalize($0.text) }
            words = Set(normalized.filter { !$0.isEmpty })
            extend(to: GlossaryCorrector.maxWindow)
        }

        /// Builds the windows of up to `size` tokens not built yet, in F65's order. The windows of
        /// up to three are built with the segment; longer ones only when a term that may be compared
        /// with them asks (F972), so one long phrase in the vocabulary no longer makes every line
        /// build windows up to its length.
        func extend(to size: Int) {
            guard size >= ends.count else { return }
            for size in ends.count...size {
                if size <= tokens.count {
                    for start in 0...(tokens.count - size) {
                        let slice = start..<(start + size)
                        let range = tokens[start].range.lowerBound..<tokens[start + size - 1].range.upperBound
                        // Joined as strings first, as F65 did, so the character count is the same.
                        let joined = normalized[slice].joined()
                        if smallestWindowSpelling[joined] == nil { smallestWindowSpelling[joined] = size }
                        all.append(Window(
                            ids: table.ids(joined),
                            phrase: String(text[range]),
                            range: range,
                            containsCJK: tokens[slice].contains(where: \.isCJK)
                        ))
                    }
                }
                ends.append(all.count)
            }
        }

        /// Where the windows of up to `size` tokens end in `all`.
        func end(ofSize size: Int) -> Int {
            ends[min(size, ends.count - 1)]
        }

        /// Whether at least `count` of `termWords` stand in the segment as whole words (F972).
        func holds(atLeast count: Int, of termWords: [String]) -> Bool {
            termWords.filter(words.contains).count >= count
        }
    }

    /// A segment's runs of letters and digits, lowercased, for sliding a Chinese term along.
    private struct CJKRuns {
        struct Run {
            var ids: [Int32] = []
            var indices: [String.Index] = []

            func end(of position: Int, in text: String) -> String.Index {
                text.index(after: indices[position])
            }
        }

        let runs: [Run]
        let characterSet: Set<Int32>
        /// Every run's characters end to end — F65's `normalize` of the segment — for the presence test.
        private let joined: [Int32]

        init(text: String, table: CharacterTable) {
            var runs: [Run] = []
            var current = Run()
            var index = text.startIndex
            while index < text.endIndex {
                let character = text[index]
                if character.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) {
                    current.ids.append(table.id(ofLowercased: character))
                    current.indices.append(index)
                } else if !current.ids.isEmpty {
                    runs.append(current)
                    current = Run()
                }
                index = text.index(after: index)
            }
            if !current.ids.isEmpty { runs.append(current) }
            self.runs = runs
            joined = runs.flatMap(\.ids)
            characterSet = Set(joined)
        }

        /// Whether `ids` occurs contiguously — the term is already in the segment, so it is correct.
        func contains(_ ids: [Int32]) -> Bool {
            guard !ids.isEmpty, ids.count <= joined.count else { return false }
            guard ids.allSatisfy(characterSet.contains) else { return false }
            for start in 0...(joined.count - ids.count) where joined[start] == ids[0] {
                if joined[start..<(start + ids.count)].elementsEqual(ids) { return true }
            }
            return false
        }
    }

    private struct PreparedTerm {
        let term: String
        let normalized: String
        let ids: [Int32]
        let isCJK: Bool
        /// `normalized`'s characters, position for position with `ids`, for the homophone check.
        let characters: [Character]
        /// The term's words, split as a segment's are (at a space or a dash, F915): a window of up
        /// to one more than this many is compared (F940, F968).
        let wordCount: Int
        /// Those words normalized, for the F972 gate: windows of more than three are compared only
        /// where the segment holds at least half of them.
        let words: [String]
        /// A two-character Chinese term that is a person's name by `ChinesePersonName` (F921):
        /// never proposed for a sound-alike window.
        let isPersonName: Bool
    }

    private final class PreparedVocabulary: @unchecked Sendable {
        let table: CharacterTable
        let terms: [PreparedTerm]
        let hasCJKTerms: Bool
        /// The evidence's known terms that could enclose a Chinese window (F594) — only a term with
        /// Chinese in it can.
        let knownCJKTerms: [String]
        /// Every Chinese term's characters, so a window that is itself a term is never proposed
        /// toward another (F916, F921).
        let cjkTermIDs: Set<[Int32]>

        init(_ vocabulary: [String], knownTerms: [String], segmenter: CJKWordEvidence.Segmenter?) {
            knownCJKTerms = knownTerms.filter { ReplacementBoundary.hasCJK($0) }
            let normalized = vocabulary.map(GlossaryCorrector.normalize)
            let table = CharacterTable(normalized)
            self.table = table
            terms = zip(vocabulary, normalized).map { term, normalized in
                let words = GlossaryCorrector.latinWords(of: term)
                let isCJK = ReplacementBoundary.hasCJK(term)
                return PreparedTerm(
                    term: term, normalized: normalized, ids: table.ids(normalized),
                    isCJK: isCJK, characters: Array(normalized),
                    wordCount: words.count, words: words.filter { !$0.isEmpty },
                    isPersonName: isCJK && ChinesePersonName.isLikely(term, segmenter: segmenter)
                )
            }
            hasCJKTerms = terms.contains(where: \.isCJK)
            cjkTermIDs = Set(terms.filter(\.isCJK).map(\.ids))
        }
    }

    /// Characters as small integers, so the LCS compares integers and allocates nothing. Built once
    /// from the terms and then only read, so worker threads can share it. A character no term
    /// contains maps to -1: it can never match, and still counts toward a window's length.
    private final class CharacterTable: @unchecked Sendable {
        private let ids: [Character: Int32]

        init(_ terms: [String]) {
            var ids: [Character: Int32] = [:]
            for term in terms {
                for character in term where ids[character] == nil {
                    ids[character] = Int32(ids.count)
                }
            }
            self.ids = ids
        }

        func ids(_ text: String) -> [Int32] {
            text.map { ids[$0] ?? -1 }
        }

        /// `normalize`'s lowercasing, one character at a time.
        func id(ofLowercased character: Character) -> Int32 {
            let lowered = String(character).lowercased()
            guard lowered.count == 1, let only = lowered.first else { return -1 }
            return ids[only] ?? -1
        }
    }

    /// One reusable LCS row, so a pass allocates per segment rather than per window.
    private struct LCSScratch {
        private var row: [Int] = []

        mutating func lcs<A: RandomAccessCollection, B: RandomAccessCollection>(_ a: A, _ b: B) -> Int
        where A.Element == Int32, B.Element == Int32 {
            guard !a.isEmpty, !b.isEmpty else { return 0 }
            let columns = b.count
            if row.count < columns + 1 { row = [Int](repeating: 0, count: columns + 1) }
            for j in 0...columns { row[j] = 0 }
            for x in a {
                var diagonal = 0
                var j = 1
                for y in b {
                    let current = row[j]
                    row[j] = x == y ? diagonal + 1 : max(row[j], row[j - 1])
                    diagonal = current
                    j += 1
                }
            }
            return row[columns]
        }
    }

    /// Reports each whole percent once, from whichever worker finishes the segment that crosses it.
    private final class ProgressTracker: @unchecked Sendable {
        private let total: Int
        private let report: @Sendable (Double) -> Void
        private let lock = NSLock()
        private var done = 0
        private var lastPercent = -1

        init(total: Int, report: @escaping @Sendable (Double) -> Void) {
            self.total = total
            self.report = report
        }

        func finishedOne() {
            lock.lock()
            done += 1
            let percent = total == 0 ? 100 : done * 100 / total
            let crossed = percent > lastPercent
            if crossed { lastPercent = percent }
            let fraction = total == 0 ? 1 : Double(done) / Double(total)
            lock.unlock()
            if crossed { report(fraction) }
        }
    }

    /// Applies reviewed corrections to a copy of the segments: within each correction's segment,
    /// replaces the first genuine occurrence of its `from` phrase with `to` — or the one at the
    /// correction's `characterOffset`, where it carries one (F950; see `place`) — (F444's
    /// `ReplacementBoundary` — the same rule the matcher used to propose it, so a proposal and its
    /// application can never disagree about which occurrence was meant: not a fragment of a longer
    /// Latin word, and not a `from` that only reads that way because it sits inside an already-`to`
    /// span, and — for a CJK `from` — not part of a longer Chinese word by `evidence`, F594). Pass the
    /// evidence the proposals were made with, or the applier can pick an occurrence the matcher
    /// refused. Segments without a correction are unchanged.
    ///
    /// **Every correction finds its place in `segments` as they stand when Apply runs, before any of
    /// this Apply's corrections (F939)**, not in the text the corrections before it already changed,
    /// and a correction whose place overlaps one an earlier correction in the list already took
    /// changes nothing. Resolved one after another, two rows for one occurrence — the local model's
    /// two readings of one word, two vocabulary terms near one mishearing — both ticked, changed that
    /// occurrence and then the next one, which no row showed; and a row whose text an earlier row
    /// wrote ("Jon → Jonathan", "Jonathan → jon") changed the word just written instead of its own.
    /// So the result no longer depends on the order of corrections in different places, and of two
    /// for one place the first wins, as the first rule does in dictation.
    ///
    /// **And a correction is applied only to the line it was reviewed on (F971):** one carrying a
    /// `proposedLine` that its segment no longer reads (`rowsOnChangedLines`) changes nothing, so
    /// "as it stands when Apply runs" is the text the row was reviewed against. A correction that
    /// names no line is resolved on the line as it stands, as before F971.
    public static func apply(
        _ corrections: [GlossaryCorrection],
        to segments: [TranscriptSegment],
        evidence: CJKWordEvidence = .none
    ) -> [TranscriptSegment] {
        var edits: [Int: [(range: Range<String.Index>, to: String)]] = [:]
        for correction in corrections where segments.indices.contains(correction.segmentIndex) {
            let index = correction.segmentIndex
            guard !lineChanged(under: correction, in: segments),
                  let range = place(of: correction, in: segments[index].text, evidence: evidence),
                  !(edits[index] ?? []).contains(where: { $0.range.overlaps(range) }) else { continue }
            edits[index, default: []].append((range, correction.to))
        }
        var result = segments
        for (index, segmentEdits) in edits {
            let text = segments[index].text
            var rebuilt = ""
            var cursor = text.startIndex
            for edit in segmentEdits.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
                rebuilt += text[cursor..<edit.range.lowerBound]
                rebuilt += edit.to
                cursor = edit.range.upperBound
            }
            rebuilt += text[cursor...]
            result[index].text = rebuilt
        }
        return result
    }

    /// Where `apply` changes `correction` in `text`: the first genuine occurrence of its `from`
    /// (F444's `ReplacementBoundary`, with `evidence` for Chinese, F594), or, for a row that carries
    /// a `characterOffset`, the genuine occurrence that starts there (F950) — nil when there is none.
    /// A row whose place no longer reads its text changes nothing, rather than the first occurrence
    /// it never showed — unless another genuine occurrence now starts at the same offset, which is
    /// why `apply` also refuses a row whose line is not the one it was proposed on (F971). The review
    /// sheet's sentence for a row is drawn around the same place (`context`).
    static func place(
        of correction: GlossaryCorrection, in text: String, evidence: CJKWordEvidence
    ) -> Range<String.Index>? {
        place(of: correction, in: SegmentedText(text, segmenter: evidence.segmenter), evidence: evidence)
    }

    /// `place(of:in:evidence:)` in a line already segmented, so several rows of one line share its
    /// segmentation (F952, `contexts`).
    static func place(
        of correction: GlossaryCorrection, in segmented: SegmentedText, evidence: CJKWordEvidence
    ) -> Range<String.Index>? {
        let text = segmented.text
        let boundary = ReplacementBoundary(heard: correction.from, notCoveredBy: correction.to, evidence: evidence)
        guard let offset = correction.characterOffset else { return boundary.firstRange(in: segmented) }
        return boundary.genuineRanges(in: segmented).first { text.distance(from: text.startIndex, to: $0.lowerBound) == offset }
    }

    /// A Latin window's phrase without the punctuation stuck to its outer words (F819): "Kestrol,"
    /// is proposed as "Kestrol", so applying it keeps the comma. A mark goes with the word only where
    /// it *is* the term's own: on the left, the longest run just before the word that ends the term's
    /// leading marks; on the right, the longest run just after it that begins the term's trailing
    /// marks. ".NOT" stays ".NOT" for ".NET" and "Acme Ink.," becomes "Acme Ink." for "Acme Inc.",
    /// so applying writes the term's "." once and the comma stays (F819's first round trimmed every
    /// mark, and `apply` wrote "..NET" and "Acme Inc.." — the Wave 5 review, T7); while "Acme Ink,"
    /// becomes "Acme Ink" and "(NOT)" becomes "NOT", because a comma is not the term's "." and a
    /// bracket is not its "." (round 2 kept marks by count, so it swallowed the comma and wrote
    /// "the .NET) runtime" — the review of round 2, R6). Only what `normalize` already ignores is
    /// trimmed — nothing the window was scored on — and never an underscore, which
    /// `ReplacementBoundary` reads as part of the word: trimmed off, `apply` would no longer find
    /// the word at all. Punctuation inside the phrase ("Kestrol, release") stays.
    static func trimmingAttachedPunctuation(_ phrase: String, keepingTheEdgesOf term: String = "") -> String {
        let characters = Array(phrase)
        return String(characters[trimmedBounds(of: phrase, keepingTheEdgesOf: term)])
    }

    /// The `Character` offsets `trimmingAttachedPunctuation` keeps of `phrase` — the whole phrase
    /// when nothing is trimmed — so a window's trimmed text can be placed in its segment (F914).
    static func trimmedBounds(of phrase: String, keepingTheEdgesOf term: String) -> Range<Int> {
        let characters = Array(phrase)
        guard let first = characters.firstIndex(where: isPartOfAWord),
              let last = characters.lastIndex(where: isPartOfAWord) else { return 0..<characters.count }
        let termLeading = Array(term.prefix(while: { !isPartOfAWord($0) }))
        let termTrailing = Array(term.reversed().prefix(while: { !isPartOfAWord($0) }).reversed())
        var leading = min(first, termLeading.count)
        while leading > 0, !characters[(first - leading)..<first].elementsEqual(termLeading.suffix(leading)) {
            leading -= 1
        }
        var trailing = min(characters.count - 1 - last, termTrailing.count)
        while trailing > 0, !characters[(last + 1)...(last + trailing)].elementsEqual(termTrailing.prefix(trailing)) {
            trailing -= 1
        }
        return (first - leading)..<(last + trailing + 1)
    }

    private static func isPartOfAWord(_ character: Character) -> Bool {
        LatinTokenBoundary.isConnector(character)
            || character.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains)
    }

    /// Alphanumerics-lowercase, separator-free — CJK-safe (ideographs are alphanumeric).
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}

/// Which proposals a review sheet should arrive with already ticked (F245).
///
/// Every proposal used to arrive pre-selected, so a model's rewrite of a term the user had taught
/// the app landed on one click — the F244 probe watched 陳經理 (a title) become 陳怡君 (a name)
/// that way. A proposal whose span overlaps a vocabulary term is now unticked and marked; the
/// user can still apply it, deliberately.
public enum GlossaryReviewDefaults {
    /// Indices of `proposals` to pre-select: everything except a proposal that touches a term.
    public static func preselected(
        _ proposals: [GlossaryCorrection], protectedTerms: [String]
    ) -> Set<Int> {
        Set(proposals.indices).subtracting(touching(proposals, protectedTerms: protectedTerms))
    }

    /// Indices of `proposals` whose span overlaps a protected term — the rows the sheet marks.
    ///
    /// The terms are prepared once for every proposal (F536). The sheet used to ask
    /// `touchesProtectedTerm` per row on every render, and each call compiled a regular expression
    /// per Latin term: measured at -O, 2–12 s for 50 proposals against 5,000 terms, 0.15 s prepared.
    public static func touching(
        _ proposals: [GlossaryCorrection], protectedTerms: [String]
    ) -> Set<Int> {
        let terms = ProtectedTerms.PreparedTerms(protectedTerms)
        return Set(proposals.indices.filter { terms.touch(proposals[$0].from) })
    }

    /// Indices of `proposals` whose span contains a Chinese character (F536) — what the app leaves
    /// unticked from Correct Toward Vocabulary, whose Chinese matches are by sound.
    public static func chineseSpans(_ proposals: [GlossaryCorrection]) -> Set<Int> {
        Set(proposals.indices.filter { ReplacementBoundary.hasCJK(proposals[$0].from) })
    }

    /// Whether applying `proposal` would rewrite a protected term.
    public static func touchesProtectedTerm(
        _ proposal: GlossaryCorrection, _ protectedTerms: [String]
    ) -> Bool {
        ProtectedTerms.touches(proposal.from, terms: protectedTerms)
    }
}
