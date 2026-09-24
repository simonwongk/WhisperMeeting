import Foundation

/// Words that must survive a model pass unchanged (F245).
///
/// The list is the user's Business Vocabulary. It is the terms they have already told the app
/// matter — the ones the correction features steer *toward* — so it is the right list to refuse
/// to let a model steer *away from*, and it is user-owned and local. Nothing here guesses which
/// words matter, and no list of anyone's protected topics ships in a public repository.
///
/// The matching rule is the F244 scorer's (`score.contains_term`), so what the bench calls
/// `term_altered` and what the app refuses are the same event: CJK matches as a substring, because
/// it has no word boundaries; Latin matches whole words, case-insensitively — an exploratory bench
/// run flagged "cult" inside "culture", which is exactly the false positive whole-word matching
/// prevents. Both sides are NFC-normalised first, so a term and its output differ by content, not by
/// composition.
public enum ProtectedTerms {
    /// Whether `text` contains `term`, by the rule `term`'s script requires.
    public static func contains(_ text: String, term: String) -> Bool {
        PreparedText(text).contains(term)
    }

    /// The terms `input` contained that `output` no longer does, in `terms` order. Measures the
    /// model, not the list: a term the dictation never used is not missing.
    public static func missing(from output: String, comparedTo input: String, terms: [String]) -> [String] {
        // Each text is prepared once for the whole list, not once per term (F437).
        let input = PreparedText(input)
        let output = PreparedText(output)
        return terms.filter { input.contains($0) && !output.contains($0) }
    }

    /// A text made ready to be searched for many terms (F437).
    ///
    /// `contains` used to NFC-normalise the text and search it as a Swift `String` for every term.
    /// Measured at -O, the searching was the cost more than the normalising: normalising once but
    /// still searching the `String` per term was no faster. Searching one `NSString` for every term
    /// is what changed it — with 105 terms, a 66,443-character English transcript went from about
    /// 1,300 ms per call to 47 ms, and a 46,000-character Mandarin one from about 950 ms to 30 ms.
    /// The matching rule and its answers are unchanged: the same Foundation search, on the same
    /// normalised text.
    private struct PreparedText {
        let text: String
        let bridged: NSString

        init(_ raw: String) {
            text = raw.precomposedStringWithCanonicalMapping
            bridged = text as NSString
        }

        func contains(_ rawTerm: String) -> Bool {
            let term = rawTerm.precomposedStringWithCanonicalMapping
            guard !term.isEmpty else { return false }
            if ProtectedTerms.hasCJK(term) {
                return text.contains(term)
            }
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: term) + "\\b"
            return bridged.range(of: pattern, options: [.regularExpression, .caseInsensitive]).location != NSNotFound
        }
    }

    /// Whether a proposed edit's span overlaps a protected term: the term lies inside the span, or
    /// the span lies inside the term (a proposal to change one word of a protected name).
    public static func touches(_ span: String, terms: [String]) -> Bool {
        let span = span.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !span.isEmpty else { return false }
        return terms.contains { term in
            contains(span, term: term) || contains(term, term: span)
        }
    }

    private static func hasCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
        }
    }
}

/// What a summary left out, in the user's own terms (F245).
///
/// A summary omits by design, and a dropped claim leaves no trace — that is the F244 probe's
/// finding, where the actor of a persecution vanished from an otherwise fluent summary. The app
/// cannot judge a claim, but it can say which of the user's vocabulary terms the transcript
/// mentions and the summary does not, which is the cheapest honest signal that something was
/// left out. Never stored: the app works it out again whenever the summary, the transcript or the
/// vocabulary changes, so it follows the vocabulary and never goes stale on disk.
public enum SummaryCoverage {
    /// Vocabulary terms present in `transcript` and absent from every part of `summary`, in
    /// `terms` order. One search of the whole transcript per term, so callers keep it off the main
    /// thread (F437).
    public static func unmentioned(
        in summary: MeetingSummary, transcript: String, terms: [String]
    ) -> [String] {
        let rendered = ([summary.summary] + summary.keyPoints + summary.actionItems.map(\.text))
            .joined(separator: "\n")
        return ProtectedTerms.missing(from: rendered, comparedTo: transcript, terms: terms)
    }
}
