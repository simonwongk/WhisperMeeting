import Foundation

/// Builds Whisper's `--initial_prompt` from a list of business-vocabulary terms (proper nouns,
/// jargon, names) so the model is nudged toward the right spelling without ever translating or
/// otherwise altering what was actually said. Shared by the meeting pipeline
/// (`LocalWhisperClient`) and Quick Dictation so both features cap and format the prompt the
/// same way.
public enum VocabularyPrompt {
    /// Keeps the prompt a light nudge rather than something long enough to dominate decoding.
    private static let maxTerms = 100
    private static let maxCharacters = 1_000

    public static func build(_ terms: [String]) -> String {
        let prompt = terms
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(maxTerms)
            .joined(separator: ", ")
        return String(prompt.prefix(maxCharacters))
    }
}
