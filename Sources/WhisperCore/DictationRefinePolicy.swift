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
    static let baseBudgetMilliseconds = 700
    static let perWordBudgetMilliseconds = 30
    static let maximumBudgetMilliseconds = 2_000
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
}
