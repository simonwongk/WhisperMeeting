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

    /// A ready-to-paste prompt the user can hand to any AI chat to generate a clean vocabulary
    /// list. Mirrors the format the Vocabulary screen expects (one term per line, original
    /// script, proper nouns/jargon only) so the chat's output pastes straight into the Add box.
    public static let generationPrompt = """
    I use a local Whisper speech-to-text tool for meetings and dictation. I can give it a \
    "vocabulary" list that biases it toward spelling names and jargon correctly. Help me build \
    that list.

    Rules for your output:
    - Output ONLY the terms, one per line. No numbering, no bullets, no definitions, no headers.
    - Include proper nouns and jargon that speech-to-text tends to get wrong: people's names, \
    company/product/project names, acronyms, technical terms, and any recurring domain words.
    - Keep each term in its original language/script (English terms in English, Chinese in 中文). \
    Do NOT romanize or translate.
    - No ordinary everyday words — only terms a transcriber would likely misspell.
    - Keep it to at most 80 terms, most important first.
    - No punctuation inside a term.

    Here is the context to pull terms from: [paste your meeting notes, agenda, team roster, \
    project docs, or just describe your work, team, and the topics you talk about].
    """

    /// The trimmed, non-empty, term-capped vocabulary list (before character-capping / joining).
    public static func terms(_ raw: [String]) -> [String] {
        Array(raw
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(maxTerms))
    }

    public static func build(_ raw: [String]) -> String {
        String(terms(raw).joined(separator: ", ").prefix(maxCharacters))
    }

    /// Whether `transcript` is just Whisper echoing the vocabulary prompt back — a known
    /// `initial_prompt` behavior on silence/noise — rather than real speech.
    ///
    /// Deliberately conservative: a single dictated vocabulary term (e.g. the user actually says
    /// "Kubernetes") is REAL and must never be dropped. So this only fires when the transcript
    /// reproduces a contiguous run of **two or more** prompt terms — the signature of prompt
    /// regurgitation, not of someone dictating one term. Comparison is punctuation/space
    /// insensitive and CJK-safe.
    public static func isPromptEcho(_ transcript: String, terms rawTerms: [String]) -> Bool {
        let cleaned = normalizedForEcho(transcript)
        guard !cleaned.isEmpty else { return false }
        let normalized = terms(rawTerms).map(normalizedForEcho).filter { !$0.isEmpty }
        guard normalized.count >= 2 else { return false }
        for start in normalized.indices {
            var joined = ""
            for end in start..<normalized.count {
                joined += normalized[end]
                if end > start, joined == cleaned { return true } // matched >= 2 consecutive terms
            }
        }
        return false
    }

    /// Lowercased, alphanumerics-only (punctuation/spaces removed; CJK letters kept), so
    /// "Acme, Q3" and "acme q3." compare equal.
    private static func normalizedForEcho(_ text: String) -> String {
        String(text.lowercased().unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(Character.init))
    }
}
