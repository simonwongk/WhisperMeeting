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
    /// `correction` in its sentence (F817): the place `apply` would change in `text` — `place(of:in:
    /// evidence:)`, the one `apply` uses, so pass the evidence the proposals are applied with — with
    /// up to `radius` characters either side, cut back to a space
    /// rather than through a word, and "…" where the text goes on. Nil when `apply` would change
    /// nothing in `text`.
    public static func context(
        of correction: GlossaryCorrection, in text: String, evidence: CJKWordEvidence = .none, radius: Int = 24
    ) -> ProposalContext? {
        guard let range = place(of: correction, in: text, evidence: evidence) else { return nil }
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
