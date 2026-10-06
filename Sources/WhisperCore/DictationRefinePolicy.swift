import Foundation

/// Pure decision layer for Quick Dictation refinement (F200): whether a transcript is worth sending
/// to the local model at all, how long the model is allowed to take, and whether its output is safe
/// to deliver in place of the user's raw words. Everything here is deterministic and headlessly
/// tested; the controller supplies only the toggle/availability checks it alone can see.
///
/// The budget is a *hard ceiling on added latency*: a missed budget delivers the raw transcript at
/// `t = budget`, so the worst case with refinement on is exactly today's behavior plus the budget.
/// That is why the constants stay modest and long dictations are skipped outright.
public enum DictationRefinePolicy {
    public enum Decision: Equatable, Sendable {
        case skip
        case attempt(budget: Duration)
    }

    /// Above this the model cannot reliably answer inside `maximumBudgetMilliseconds` — skip,
    /// don't tease the user with a budget that will always be missed.
    public static let maximumWordCount = 60
    /// F206 remeasured the cached, primed 8B helper at 520–690 ms per request on the target Mac.
    /// The previous 1.2 s + 30 ms/word / 2.5 s ceiling predated that cache and made an optional
    /// polish pass visibly dominate a fast Qwen dictation. Keep a small observed-performance
    /// margin, but deliver the safe raw transcript promptly whenever polishing misses it.
    static let baseBudgetMilliseconds = 800
    static let perWordBudgetMilliseconds = 20
    static let maximumBudgetMilliseconds = 1_500
    /// Output cap sent to the helper. ≤60 words in either language is well under this; the cap
    /// bounds how long an abandoned (timed-out) generation can occupy the resident server.
    public static let maxOutputTokens = 256

    public static func decision(for text: String) -> Decision {
        let words = effectiveWordCount(of: text)
        guard words > 0, words <= maximumWordCount else { return .skip }
        let milliseconds = min(
            baseBudgetMilliseconds + perWordBudgetMilliseconds * words,
            maximumBudgetMilliseconds
        )
        return .attempt(budget: .milliseconds(milliseconds))
    }

    /// Space-delimited word count, except majority-CJK text (no word spaces) where it is
    /// ceil(non-whitespace characters / 2) — reusing the F32 dominant-script heuristic.
    public static func effectiveWordCount(of text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        if TranscriptLanguage.dominant(of: trimmed) == .chinese {
            let characters = trimmed.unicodeScalars.filter { !$0.properties.isWhitespace }.count
            return (characters + 1) / 2
        }
        return trimmed.split(whereSeparator: { $0.isWhitespace }).count
    }

    // MARK: - Output guardrails (F165 ethos: never trust LLM output blindly)

    /// The model's reply, cleaned and vetted — or nil, in which case the raw transcript must be
    /// delivered. Mirrors the F165 verbatim-guard ethos: a rejection costs nothing (raw is what
    /// ships today); an accepted hallucination costs trust. So every check biases toward raw.
    public static func acceptedOutput(_ output: String, input: String) -> String? {
        acceptedOutput(output, input: input, protectedTerms: [])
    }

    /// As above, and additionally refuses an output that lost a protected term the input contained
    /// (F245). The terms are the user's Business Vocabulary; the rule is `ProtectedTerms`, which is
    /// the F244 scorer's rule, so the bench's `term_altered` and this refusal are one event. The
    /// cost is the usual one — the raw transcript ships — which is the right side to err on for a
    /// word the user went to the trouble of teaching the app.
    public static func acceptedOutput(
        _ output: String, input: String, protectedTerms: [String]
    ) -> String? {
        let cleanedInput = DictationTextCleanup.clean(input)
        var candidate = output.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate = strippingCodeFence(candidate)
        // F488: quotes around the whole dictation are the user's, whichever pair the output keeps
        // them in (a model may restyle `"…"` as `“…”`). So a quoted dictation loses a layer only
        // when one is left over — the model wrapped the user's quotes in its own.
        let stripped = strippingWrappingQuotes(candidate)
        if wrappingQuotes(of: cleanedInput) == nil || wrappingQuotes(of: stripped) != nil {
            candidate = stripped
        }
        candidate = DictationTextCleanup.clean(candidate)
        guard !candidate.isEmpty else { return nil }

        let inputCount = cleanedInput.count
        // Light-touch edits barely move length; filler removal shrinks a little. The +4 absolute
        // slack keeps one-word dictations ("hi" → "Hi.") from tripping the ratio.
        let lower = inputCount / 2
        let upper = inputCount + inputCount / 2 + 4
        guard (lower...upper).contains(candidate.count) else { return nil }

        if let inputScript = TranscriptLanguage.dominant(of: cleanedInput) {
            guard TranscriptLanguage.dominant(of: candidate) == inputScript else { return nil }
        }
        // F245: the same tripwire, for the crossing the one above cannot see. `dominant` answers
        // "which language", and Traditional and Simplified are one language — so a Traditional
        // dictation returned as Simplified passed every check here and was pasted over the user's
        // words. Measured by F244's harness on neutral content; the guard accepted it.
        //
        // Rejecting costs nothing, which is this whole function's ethos: the raw transcript ships,
        // which is exactly what happens today whenever refinement is off or slow.
        guard !ScriptDrift.isSimplifyingConversion(source: cleanedInput, output: candidate) else {
            return nil
        }
        // F589: a code-switched dictation's dominant script never changes when a cleanup
        // TRANSLATES the embedded minority-script word into the majority language instead of
        // preserving it — "Please send the 会议纪要 to the whole team before 周五." and "Please
        // send the meeting minutes to the whole team before Friday." are both majority-English, so
        // the dominant-script guard above cannot see this crossing at all. F637: and it must count
        // the embedded words, not ask whether their script survived — cs3's "这个 bug 已经 fix 了，
        // 可以 merge 了。" came back with "fix" and "merge" translated and "bug" kept, which a
        // presence check accepts. A cleanup that keeps every embedded word still passes.
        guard !droppedEmbeddedWord(source: cleanedInput, output: candidate, protectedTerms: protectedTerms)
        else { return nil }
        guard ProtectedTerms.missing(from: candidate, comparedTo: cleanedInput, terms: protectedTerms).isEmpty
        else { return nil }
        return candidate
    }

    /// Whether `output` lost a word `source` said in its minority script (F589, F637).
    ///
    /// Two checks with different blind spots, kept together:
    ///
    /// - **Presence (F589).** A script the source used at all — any CJK ideograph (`U+3400…U+9FFF`,
    ///   the range `TranscriptLanguage.dominant` scores) as Mandarin, any other letter as Latin —
    ///   must still appear in the output.
    /// - **Count (F637).** Each token of the source's minority script must still be there, as many
    ///   times as the source said it. Tokens are F468's, so this guard and `dominant(of:)` agree on
    ///   what a word is: one per CJK ideograph, one per run of other alphanumerics. A Latin token is
    ///   compared after NFKC and lowercasing, and punctuation and spaces are never part of a token,
    ///   so a cleanup may recase, re-space and re-punctuate an embedded word but not translate it.
    ///   Only the minority script is counted: the majority's fillers ("um", 嗯) are what a cleanup
    ///   is asked to remove. A run of digits is a number, not a script, so 3 → 三 is not a lost
    ///   English word.
    ///
    /// One exception, which `ProtectedTerms` recognises (F245's rule): a missing token is excused by
    /// a vocabulary term the output gained and the source lacked — a refiner correcting a misheard
    /// word to the user's own term. A term excuses only as many tokens as it newly brings, so it
    /// can stand in for the word it replaced and not for a second word translated beside it.
    ///
    /// Erring towards refusal costs nothing: the raw transcript ships, as it does whenever
    /// refinement is off or slow. Known refusals of an edit that kept the word: a Latin word joined
    /// or split at a hyphen or apostrophe ("e-mail" → "email"), and a filler in the minority script.
    private static func droppedEmbeddedWord(source: String, output: String, protectedTerms: [String]) -> Bool {
        func hasCJK(_ text: String) -> Bool { text.unicodeScalars.contains(where: isCJKIdeograph) }
        func hasLatinLetter(_ text: String) -> Bool {
            text.unicodeScalars.contains { CharacterSet.letters.contains($0) && !isCJKIdeograph($0) }
        }
        if hasCJK(source), !hasCJK(output) { return true }
        if hasLatinLetter(source), !hasLatinLetter(output) { return true }

        guard let dominant = TranscriptLanguage.dominant(of: source) else { return false }
        // The minority script: Latin inside Mandarin, CJK inside English.
        let minority: TranscriptLanguage = dominant == .chinese ? .english : .chinese
        let said = embeddedTokens(of: source, script: minority)
        guard !said.isEmpty else { return false }
        let kept = embeddedTokens(of: output, script: minority)
        let missing = said.reduce(0) { $0 + max(0, $1.value - kept[$1.key, default: 0]) }
        guard missing > 0 else { return false }

        let gainedTerms = protectedTerms.filter {
            ProtectedTerms.contains(output, term: $0) && !ProtectedTerms.contains(source, term: $0)
        }
        let termTokens = Set(gainedTerms.flatMap { embeddedTokens(of: $0, script: minority).keys })
        let corrections = termTokens.reduce(0) { $0 + max(0, kept[$1, default: 0] - said[$1, default: 0]) }
        return missing > corrections
    }

    private static func isCJKIdeograph(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x3400 && scalar.value <= 0x9FFF
    }

    /// `text`'s tokens of one script, counted (F637): `.chinese` gives one token per CJK ideograph,
    /// `.english` one per run of other alphanumerics (lowercased, NFKC), skipping digit-only runs.
    /// Runs end at whitespace, at a CJK ideograph and at punctuation, exactly as
    /// `TranscriptLanguage.dominant(of:)` ends them.
    private static func embeddedTokens(of text: String, script: TranscriptLanguage) -> [String: Int] {
        var counts: [String: Int] = [:]
        var run = String.UnicodeScalarView()
        func endRun() {
            defer { run = String.UnicodeScalarView() }
            guard script == .english, !run.isEmpty,
                  !run.allSatisfy({ $0.properties.numericType != nil }) else { return }
            counts[String(run).lowercased(), default: 0] += 1
        }
        for scalar in text.precomposedStringWithCompatibilityMapping.unicodeScalars {
            if isCJKIdeograph(scalar) {
                endRun()
                if script == .chinese { counts[String(scalar), default: 0] += 1 }
            } else if CharacterSet.alphanumerics.contains(scalar) {
                run.append(scalar)
            } else {
                endRun()
            }
        }
        endRun()
        return counts
    }

    private static func strippingCodeFence(_ text: String) -> String {
        guard text.hasPrefix("```") else { return text }
        var lines = text.components(separatedBy: "\n")
        lines.removeFirst()
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let quotePairs: [(open: Character, close: Character)] = [
        ("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’"), ("「", "」"), ("『", "』"),
    ]

    /// The quote pair `text` begins and ends with, if any.
    private static func wrappingQuotes(of text: String) -> (open: Character, close: Character)? {
        guard text.count >= 2 else { return nil }
        return quotePairs.first { text.first == $0.open && text.last == $0.close }
    }

    private static func strippingWrappingQuotes(_ text: String) -> String {
        guard wrappingQuotes(of: text) != nil else { return text }
        return String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
