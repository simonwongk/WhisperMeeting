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
            // Not `\b…\b` (F534): ICU's regex word-boundary counts a Han ideograph as a word
            // character, so there is no boundary between it and an adjacent Latin letter, and a
            // Latin term written against Chinese characters with no separating space — Whisper and
            // Qwen routinely write code-switched Mandarin this way, e.g. "这个Kubernetes集群" —
            // never "contained" a term at all. Assert directly on what must NOT be adjacent (a
            // Latin letter, digit or underscore — `LatinTokenBoundary`, shared with
            // `ReplacementBoundary` since F592) instead of asking ICU what counts as a boundary.
            // A Han character fails that assertion just like a space would, so it now counts as a
            // boundary; two adjacent Latin terms ("Kubernetes2", "CCPA") still do not, which is
            // exactly the whole-word behaviour the older pattern gave for pure Latin text.
            let boundaryClass = LatinTokenBoundary.regexCharacterClass
            let pattern = "(?<![\(boundaryClass)])" + NSRegularExpression.escapedPattern(for: term) + "(?![\(boundaryClass)])"
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

    /// Many terms made ready to be tested against many spans (F536) — `touches` for a whole review
    /// sheet. `touches` prepares its span and compiles a regular expression per Latin term on every
    /// call, which is fine for one proposal and took 2–12 s for a sheet of 50 against 5,000 terms
    /// (two -O runs on a loaded machine; 0.15 s prepared, F536's closure has the output). This
    /// prepares each term once — its normalised text, and its whole-word expression compiled once —
    /// and gives the same answer as `touches(_:terms:)` for every span, because it asks the same two
    /// questions with the same patterns and options.
    public struct PreparedTerms {
        private struct Term {
            let text: String
            let bridged: NSString
            let matcher: Matcher
        }

        private let terms: [Term]

        public init(_ terms: [String]) {
            self.terms = terms.compactMap { raw in
                // As `PreparedText.contains` does to a term; an empty one never matches either way.
                let text = raw.precomposedStringWithCanonicalMapping
                guard !text.isEmpty else { return nil }
                return Term(text: text, bridged: text as NSString, matcher: Matcher(text))
            }
        }

        /// `ProtectedTerms.touches(span, terms:)`, with the terms already prepared.
        public func touch(_ span: String) -> Bool {
            let trimmed = span.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            let prepared = PreparedText(trimmed)
            let spanMatcher = Matcher(prepared.text)
            return terms.contains { term in
                // The span contains the term, or the term contains the span.
                term.matcher.occurs(in: prepared.text, bridged: prepared.bridged)
                    || spanMatcher.occurs(in: term.text, bridged: term.bridged)
            }
        }
    }

    /// `PreparedText.contains`'s rule for one already-normalised needle, compiled once: a substring
    /// for CJK, and for Latin the same whole-word expression and options, which `range(of:options:)`
    /// would compile on every call.
    private enum Matcher {
        case substring(String)
        case wholeWord(NSRegularExpression?)

        init(_ needle: String) {
            if ProtectedTerms.hasCJK(needle) {
                self = .substring(needle)
            } else {
                self = .wholeWord(ProtectedTerms.wholeWordExpression(for: needle))
            }
        }

        func occurs(in text: String, bridged: NSString) -> Bool {
            switch self {
            case let .substring(needle):
                return !needle.isEmpty && text.contains(needle)
            case let .wholeWord(expression):
                // An expression that did not compile finds nothing, as `range(of:options:)` would.
                return expression?.firstMatch(in: text, range: NSRange(location: 0, length: bridged.length)) != nil
            }
        }
    }

    /// The expression `PreparedText.contains` searches with for a Latin term.
    fileprivate static func wholeWordExpression(for term: String) -> NSRegularExpression? {
        let boundaryClass = LatinTokenBoundary.regexCharacterClass
        let pattern = "(?<![\(boundaryClass)])" + NSRegularExpression.escapedPattern(for: term) + "(?![\(boundaryClass)])"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
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
