import Foundation

/// A correction proposal in its sentence (F817): the words around the place `GlossaryCorrector.apply`
/// would change, so a review row can be checked where it is. A Chinese match by sound can be another
/// real word or another person's name (经历 for 经理, 张薇 for 张伟 — the Wave 5 review of F817), and
/// the row's "from → to" alone cannot say which.
public struct ProposalContext: Sendable, Equatable {
    /// The text before the change, with "…" in front when the segment goes on further back.
    public let before: String
    /// The text the proposal would replace.
    public let match: String
    /// The text after the change, with "…" behind when the segment goes on.
    public let after: String

    public init(before: String, match: String, after: String) {
        self.before = before
        self.match = match
        self.after = after
    }
}

extension GlossaryCorrector {
    /// `corrections`, each carrying the text of its line in `segments` — the lines they were proposed
    /// on — for a review sheet (F971). `apply` then changes a row only while its line still reads so.
    public static func proposing(_ corrections: [GlossaryCorrection], on segments: [TranscriptSegment]) -> [GlossaryCorrection] {
        corrections.map { correction in
            GlossaryCorrection(
                segmentIndex: correction.segmentIndex, from: correction.from, to: correction.to,
                characterOffset: correction.characterOffset,
                proposedLine: segments.indices.contains(correction.segmentIndex) ? segments[correction.segmentIndex].text : nil
            )
        }
    }

    /// The indices of the `corrections` that `apply` would skip because their line changed since
    /// they were proposed (F971): each carries a `proposedLine` that its segment no longer reads, or
    /// its segment is gone. A correction that names no line is never counted.
    public static func rowsOnChangedLines(_ corrections: [GlossaryCorrection], in segments: [TranscriptSegment]) -> [Int] {
        corrections.indices.filter { lineChanged(under: corrections[$0], in: segments) }
    }

    static func lineChanged(under correction: GlossaryCorrection, in segments: [TranscriptSegment]) -> Bool {
        guard let proposedLine = correction.proposedLine else { return false }
        return !segments.indices.contains(correction.segmentIndex) || segments[correction.segmentIndex].text != proposedLine
    }

    /// Every row's sentence at once, for a review sheet to work out when it opens (F952): what
    /// `context(of:in:evidence:radius:)` gives each row, nil for a row whose line is gone. Each line
    /// is segmented once however many rows it has, and the vocabulary is scanned for terms that
    /// could enclose a row's text once per distinct text. The sheet asked per row in each row's body,
    /// so every redraw — every tick — ran NLTokenizer over a Chinese row's line and scanned the
    /// whole vocabulary: 0.249 s per pass over 50 rows at the 5,000-term cap (the Wave 5 review of
    /// F817, R7). A row that carries the line it was proposed on is drawn on that line (F971) — the
    /// only line `apply` will change it on — so a sentence never shows a place Apply would not write.
    public static func contexts(
        of corrections: [GlossaryCorrection], in segments: [TranscriptSegment], evidence: CJKWordEvidence = .none
    ) -> [ProposalContext?] {
        var lines: [String: SegmentedText] = [:]
        var enclosing: [String: CJKWordEvidence] = [:]
        return corrections.map { correction in
            let index = correction.segmentIndex
            guard segments.indices.contains(index) else { return nil }
            let text = correction.proposedLine ?? segments[index].text
            let line = lines[text] ?? SegmentedText(text, segmenter: evidence.segmenter)
            lines[text] = line
            let rowEvidence = enclosing[correction.from] ?? CJKWordEvidence(
                segmenter: evidence.segmenter,
                knownTerms: ReplacementBoundary.termsThatCouldEnclose(correction.from, among: evidence.knownTerms)
            )
            enclosing[correction.from] = rowEvidence
            return context(of: correction, in: line, evidence: rowEvidence, radius: 24)
        }
    }

    /// Rows that change one place (F966): for each row whose place overlaps another row's place on
    /// the same line, the index of the first row of its group; a row alone at its place is absent.
    ///
    /// `apply` changes a place once, with the first ticked row that reaches it (F939), so two such
    /// rows — the local model's two readings of one word, two vocabulary terms near one mishearing —
    /// are alternatives, not two changes. Places are `apply`'s own (`place(of:in:evidence:)`) on the
    /// line each row was proposed on (F971), as `contexts` draws them. Overlap is taken through a
    /// chain (A over B, B over C), so such a group asks for one choice where `apply` could take two
    /// — the safe side: a row unticked by the sheet can be ticked again after Apply.
    public static func alternatives(
        of corrections: [GlossaryCorrection], in segments: [TranscriptSegment], evidence: CJKWordEvidence = .none
    ) -> [Int: Int] {
        var lines: [String: SegmentedText] = [:]
        var placed: [String: [(row: Int, range: Range<Int>)]] = [:]
        for (row, correction) in corrections.enumerated() where segments.indices.contains(correction.segmentIndex) {
            let text = correction.proposedLine ?? segments[correction.segmentIndex].text
            let line = lines[text] ?? SegmentedText(text, segmenter: evidence.segmenter)
            lines[text] = line
            let rowEvidence = CJKWordEvidence(
                segmenter: evidence.segmenter,
                knownTerms: ReplacementBoundary.termsThatCouldEnclose(correction.from, among: evidence.knownTerms)
            )
            guard let range = place(of: correction, in: line, evidence: rowEvidence) else { continue }
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            let key = "\(correction.segmentIndex)\u{0}\(text)"
            placed[key, default: []].append((row, start..<(start + text.distance(from: range.lowerBound, to: range.upperBound))))
        }
        var groups: [Int: Int] = [:]
        for rows in placed.values {
            var cluster: [Int] = []
            var reach = 0
            func close() {
                if cluster.count > 1, let first = cluster.min() { for row in cluster { groups[row] = first } }
                cluster = []
            }
            for item in rows.sorted(by: { ($0.range.lowerBound, $0.row) < ($1.range.lowerBound, $1.row) }) {
                if !cluster.isEmpty, item.range.lowerBound >= reach { close() }
                reach = cluster.isEmpty ? item.range.upperBound : max(reach, item.range.upperBound)
                cluster.append(item.row)
            }
            close()
        }
        return groups
    }

    /// `correction` in its sentence (F817): the place `apply` would change in `text` — `place(of:in:
    /// evidence:)`, the one `apply` uses, so pass the evidence the proposals are applied with — with
    /// up to `radius` characters either side, cut back to a space
    /// rather than through a word, and "…" where the text goes on. Nil when `apply` would change
    /// nothing in `text`.
    public static func context(
        of correction: GlossaryCorrection, in text: String, evidence: CJKWordEvidence = .none, radius: Int = 24
    ) -> ProposalContext? {
        context(of: correction, in: SegmentedText(text, segmenter: evidence.segmenter), evidence: evidence, radius: radius)
    }

    private static func context(
        of correction: GlossaryCorrection, in segmented: SegmentedText, evidence: CJKWordEvidence, radius: Int
    ) -> ProposalContext? {
        let text = segmented.text
        guard let range = place(of: correction, in: segmented, evidence: evidence) else { return nil }
        var start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        if start > text.startIndex, !text[text.index(before: start)].isWhitespace,
           let space = text[start..<range.lowerBound].firstIndex(where: \.isWhitespace) {
            start = text.index(after: space)
        }
        var end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        if end < text.endIndex, !text[end].isWhitespace,
           let space = text[range.upperBound..<end].lastIndex(where: \.isWhitespace) {
            end = space
        }
        return ProposalContext(
            before: (start > text.startIndex ? "…" : "") + String(text[start..<range.lowerBound]),
            match: String(text[range]),
            after: String(text[range.upperBound..<end]) + (end < text.endIndex ? "…" : "")
        )
    }
}
