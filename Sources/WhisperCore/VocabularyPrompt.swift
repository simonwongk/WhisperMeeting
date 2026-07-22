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
