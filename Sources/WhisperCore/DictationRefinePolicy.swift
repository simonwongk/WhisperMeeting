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
        var candidate = output.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate = strippingCodeFence(candidate)
        candidate = strippingWrappingQuotes(candidate)
        candidate = DictationTextCleanup.clean(candidate)
        guard !candidate.isEmpty else { return nil }

        let cleanedInput = DictationTextCleanup.clean(input)
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
        guard ProtectedTerms.missing(from: candidate, comparedTo: cleanedInput, terms: protectedTerms).isEmpty
        else { return nil }
        return candidate
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

    private static func strippingWrappingQuotes(_ text: String) -> String {
        let pairs: [(Character, Character)] = [
            ("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’"), ("「", "」"), ("『", "』"),
        ]
        for (open, close) in pairs where text.count >= 2 {
            if text.first == open, text.last == close {
                return String(text.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }
}
