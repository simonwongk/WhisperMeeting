import Foundation

/// A proposed, user-reviewable spelling correction toward a vocabulary term (F65).
public struct GlossaryCorrection: Sendable, Equatable {
    public let segmentIndex: Int
    public let from: String
    public let to: String

    public init(segmentIndex: Int, from: String, to: String) {
        self.segmentIndex = segmentIndex
        self.from = from
        self.to = to
    }
}

/// Pure near-miss matching of transcript spans against the user's vocabulary. For each term it finds
/// the best window in a segment whose normalized form is similar enough (longest-common-subsequence
/// ratio) to the term, skipping exact matches and too-distant/cross-script candidates. The user
/// reviews every proposal before it applies; nothing auto-applies (F65).
///
/// **Two kinds of window (F536).** A Latin term is compared with windows of one to three
/// whitespace-separated words — unchanged from F65, and pinned against a verbatim copy of the old
/// code by `GlossaryCorrectorGoldenTests`. A term containing Chinese is compared with windows of
/// exactly its own length, slid character by character along each run of letters and digits: Chinese
/// has no spaces, so the old whitespace split made a whole sentence one "word" — a short segment was
/// proposed to be replaced wholesale ("对，张经里" → "张经理", deleting "对，") and a mishearing
/// inside an ordinary sentence was never found. A term already present in the segment is correct and
/// proposes nothing, and a window must match MORE than half the term's characters, position for
/// position: at exactly half, a two-character term would match every word sharing one character with
/// it (计算 for 预算), so a two-character term is only ever matched exactly. A Chinese window is
/// only proposed where `GlossaryCorrector.apply` would apply it — `ReplacementBoundary` with the
/// caller's `CJKWordEvidence` (F594) — so a window cutting through a word is not offered. A Latin
/// term's windows split a token where Latin meets Chinese ("这个Kubernets集群"), so the proposal
/// replaces "Kubernets", not the Chinese on either side; text without Chinese splits as it did.
///
/// **Cost (F536).** This ran segment × term × window with an O(n·m) LCS and re-normalized every term
/// for every segment, on the main actor — the round-2 sweep measured about 136 s for one meeting at
/// the 5,000-term cap. Each term is now prepared once, a Latin window whose length alone rules out
/// the threshold (or cannot beat the best found so far) is skipped before any LCS, and segments run
/// in parallel with progress and cancellation (`corrections(vocabulary:segments:evidence:
/// isCancelled:progress:)`). Measured at -O on a 700-segment synthetic meeting against 5,000 terms:
/// 78.9 s before, 1.2 s after, with the same 167,128 proposals.
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
        let prepared = PreparedVocabulary(vocabulary, knownTerms: evidence.knownTerms)
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
        let latin = LatinWindows(tokens: tokens, table: prepared.table)
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
        var results: [GlossaryCorrection] = []
        for term in prepared.terms where !term.ids.isEmpty {
            let phrase: String?
            if term.isCJK {
                guard let chinese else { continue }
                phrase = bestCJKWindow(for: term, in: chinese, text: text, segmented: segmented,
                                       evidence: segmentEvidence)
            } else {
                phrase = bestLatinWindow(for: term, in: latin, scratch: &scratch)
            }
            if let phrase {
                results.append(GlossaryCorrection(segmentIndex: segmentIndex, from: phrase, to: term.term))
            }
        }
        return results
    }

    /// F65's search, unchanged in what it returns for text without Chinese: the first 1–3-token
    /// window with the highest ratio at or above the threshold, not equal to the term, unless the
    /// term already stands as a token.
    private static func bestLatinWindow(
        for term: PreparedTerm, in windows: LatinWindows, scratch: inout LCSScratch
    ) -> String? {
        if windows.normalizedTokens.contains(term.normalized) { return nil }
        var best: (similarity: Double, phrase: String)?
        for window in windows.all where !window.containsCJK && !window.ids.isEmpty && window.ids != term.ids {
            let longer = max(window.ids.count, term.ids.count)
            // The LCS is at most the shorter length, so this ratio bounds the score: skip a window
            // that cannot reach the threshold, or cannot beat the best already found (F536).
            let bound = Double(min(window.ids.count, term.ids.count)) / Double(longer)
            guard bound >= similarityThreshold, bound > (best?.similarity ?? 0) else { continue }
            let score = Double(scratch.lcs(window.ids, term.ids)) / Double(longer)
            if score >= similarityThreshold, score > (best?.similarity ?? 0) {
                best = (score, window.phrase)
            }
        }
        return best?.phrase
    }

    /// The best window of exactly the term's length in any run of letters and digits (F536), or nil
    /// when the term is already present, no window matches more than half its characters position
    /// for position, or the only such windows cut through a word.
    ///
    /// Position for position rather than an LCS: a Chinese mishearing substitutes a character for a
    /// homophone and keeps the length (张经理 → 张经里), and an LCS also credits the window one
    /// character to the left — 请张经 shares 张经 with 张经理 as a subsequence, and comes first.
    private static func bestCJKWindow(
        for term: PreparedTerm, in runs: CJKRuns, text: String, segmented: SegmentedText,
        evidence: () -> CJKWordEvidence
    ) -> String? {
        let length = term.ids.count
        // Cheap upper bound first: every matched character must occur in the segment somewhere.
        guard term.ids.count(where: runs.characterSet.contains) * 2 > length else { return nil }
        if runs.contains(term.ids) { return nil }
        var best: (score: Int, phrase: String)?
        for run in runs.runs where run.ids.count >= length {
            for start in 0...(run.ids.count - length) {
                var common = 0
                for offset in 0..<length where run.ids[start + offset] == term.ids[offset] {
                    common += 1
                }
                // More than half, strictly, and better than the best genuine window so far.
                guard common * 2 > length, common > (best?.score ?? 0) else { continue }
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

    // MARK: - Preparation (F536: once per pass, not once per segment × term)

    /// A Latin term's windows are whitespace-separated words, as before F536, further split where a
    /// Chinese character meets a non-Chinese one, so code-switched text written without spaces
    /// ("这个Kubernets集群") yields "Kubernets" rather than the whole run.
    private struct Token {
        let text: String
        /// Whether this token continues the previous one with no whitespace between them.
        let joinsPrevious: Bool
        let isCJK: Bool
    }

    private static func latinTokens(of text: String) -> [Token] {
        var tokens: [Token] = []
        for word in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            var piece = ""
            var pieceIsCJK = false
            var first = true
            for character in word {
                let isCJK = ReplacementBoundary.hasCJK(String(character))
                if !piece.isEmpty, isCJK != pieceIsCJK {
                    tokens.append(Token(text: piece, joinsPrevious: !first, isCJK: pieceIsCJK))
                    first = false
                    piece = ""
                }
                piece.append(character)
                pieceIsCJK = isCJK
            }
            if !piece.isEmpty {
                tokens.append(Token(text: piece, joinsPrevious: !first, isCJK: pieceIsCJK))
            }
        }
        return tokens
    }

    private struct LatinWindows {
        struct Window {
            let ids: [Int32]
            let phrase: String
            let containsCJK: Bool
        }

        let normalizedTokens: Set<String>
        /// In F65's order: every one-token window, then every two-token window, then three.
        let all: [Window]

        init(tokens: [Token], table: CharacterTable) {
            let normalized = tokens.map { GlossaryCorrector.normalize($0.text) }
            normalizedTokens = Set(normalized)
            var windows: [Window] = []
            for size in 1...GlossaryCorrector.maxWindow where size <= tokens.count {
                for start in 0...(tokens.count - size) {
                    let slice = start..<(start + size)
                    var phrase = tokens[start].text
                    for index in (start + 1)..<(start + size) {
                        phrase += (tokens[index].joinsPrevious ? "" : " ") + tokens[index].text
                    }
                    windows.append(Window(
                        // Joined as strings first, as F65 did, so the character count is the same.
                        ids: table.ids(normalized[slice].joined()),
                        phrase: phrase,
                        containsCJK: tokens[slice].contains(where: \.isCJK)
                    ))
                }
            }
            all = windows
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
    }

    private final class PreparedVocabulary: @unchecked Sendable {
        let table: CharacterTable
        let terms: [PreparedTerm]
        let hasCJKTerms: Bool
        /// The evidence's known terms that could enclose a Chinese window (F594) — only a term with
        /// Chinese in it can.
        let knownCJKTerms: [String]

        init(_ vocabulary: [String], knownTerms: [String]) {
            knownCJKTerms = knownTerms.filter { ReplacementBoundary.hasCJK($0) }
            let normalized = vocabulary.map(GlossaryCorrector.normalize)
            let table = CharacterTable(normalized)
            self.table = table
            terms = zip(vocabulary, normalized).map { term, normalized in
                PreparedTerm(
                    term: term, normalized: normalized, ids: table.ids(normalized),
                    isCJK: ReplacementBoundary.hasCJK(term)
                )
            }
            hasCJKTerms = terms.contains(where: \.isCJK)
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
    /// replaces the first genuine occurrence of its `from` phrase with `to` (F444's
    /// `ReplacementBoundary` — the same rule the matcher used to propose it, so a proposal and its
    /// application can never disagree about which occurrence was meant: not a fragment of a longer
    /// Latin word, and not a `from` that only reads that way because it sits inside an already-`to`
    /// span, and — for a CJK `from` — not part of a longer Chinese word by `evidence`, F594). Pass the
    /// evidence the proposals were made with, or the applier can pick an occurrence the matcher
    /// refused. Segments without a correction are unchanged; corrections are order-independent (each
    /// targets a specific segment index).
    public static func apply(
        _ corrections: [GlossaryCorrection],
        to segments: [TranscriptSegment],
        evidence: CJKWordEvidence = .none
    ) -> [TranscriptSegment] {
        var result = segments
        for correction in corrections {
            guard result.indices.contains(correction.segmentIndex),
                  let range = ReplacementBoundary.firstRange(
                    of: correction.from, notCoveredBy: correction.to,
                    in: result[correction.segmentIndex].text, evidence: evidence
                  ) else { continue }
            result[correction.segmentIndex].text.replaceSubrange(range, with: correction.to)
        }
        return result
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

    /// Whether applying `proposal` would rewrite a protected term.
    public static func touchesProtectedTerm(
        _ proposal: GlossaryCorrection, _ protectedTerms: [String]
    ) -> Bool {
        ProtectedTerms.touches(proposal.from, terms: protectedTerms)
    }
}
