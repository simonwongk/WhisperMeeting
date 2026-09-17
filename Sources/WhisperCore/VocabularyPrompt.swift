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

    // MARK: - Token budget (F265)

    /// Whisper's ceiling on a **carried** initial prompt: `n_text_ctx // 2 - 1`
    /// (`whisper/transcribe.py:238`), which is 223 on both installed 448-context checkpoints.
    ///
    /// Exceeding it does not truncate the prompt — it *evicts* it. `transcribe.py:242` subtracts the
    /// prompt's token count, and at zero or below `:290`'s `all_tokens[…][-remaining:]` stops being a
    /// tail slice (`[-0:]` is the whole history; a negative value drops a fixed prefix instead).
    /// `:291` then puts the vocabulary first and `decoding.py:609` truncates to the tail, so the
    /// terms the user typed are the exact thing thrown away. Measured against a 5,000-token history:
    /// 150 tokens of vocabulary survive whole, 223 and 300 survive as none at all.
    static let whisperCarriedPromptTokenLimit = 223

    /// The budget `build` holds itself to — strictly under the limit above, with real headroom.
    ///
    /// Strictly under matters: at exactly the limit `remaining_prompt_length` is 0, which is the
    /// `[-0:]` branch. The headroom covers `estimatedTokenCount` being an estimate: swept over 9,600
    /// simulated builds against the installed runtime's own tokenizer, the worst accepted prompt
    /// measured **171** real tokens, leaving 52 to spare, and nothing exceeded the limit.
    static let promptTokenBudget = 170

    /// A deliberately conservative token estimate for a term list (F265).
    ///
    /// Whisper's BPE charges per word-ish unit, not per character, so this is modelled per term
    /// rather than as a characters × ratio: roughly one token per three ASCII characters, two per
    /// non-ASCII scalar, plus one for the separator and word-start overhead. Measured with
    /// `whisper.tokenizer.get_tokenizer(multilingual=True)`: English runs 0.24–0.32 tokens/char, CJK
    /// 1.28 and up to 2.27 for CJK punctuation — which is why a single characters-based cap cannot
    /// serve both, and why 1,000 characters of Chinese terms overran a 223-token budget ~6×.
    ///
    /// Swift has no Whisper tokenizer, so this cannot be exact. It is tuned to over-estimate (mean
    /// 1.23× actual) and paired with the headroom above, because the failure it prevents is a cliff:
    /// one token too many loses the entire vocabulary, not a term or two.
    static func estimatedTokenCount(of terms: [String]) -> Int {
        terms.reduce(0) { total, term in
            let ascii = term.unicodeScalars.count { $0.isASCII }
            let other = term.unicodeScalars.count - ascii
            return total + Int(ceil(Double(ascii) / 3.0)) + other * 2 + 1
        }
    }

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

    /// The prompt to pass as `--initial_prompt`, trimmed to fit Whisper's carried-prompt budget.
    ///
    /// Accumulates whole terms while they fit (F265). Two deliberate choices: it preserves input
    /// order and drops from the END, so trimming is predictable rather than arbitrary; and it never
    /// truncates mid-term, which `prefix(maxCharacters)` could, because a fragment is noise the
    /// decoder is being told to expect. `maxCharacters` remains a coarse outer bound — the token
    /// budget binds first.
    ///
    /// "First" means *as given*, which is not the same as "as the user typed" on the meeting path:
    /// `MeetingStore.promptSafeTerms` de-duplicates through a `Set` and sorts
    /// `localizedCaseInsensitiveCompare`, so what arrives here is alphabetised and the terms dropped
    /// are the alphabetically-last ones. That is arbitrary from the user's point of view — which
    /// only started to matter once trimming became real, and is filed as **F272**.
    public static func build(_ raw: [String]) -> String {
        String(promptedTerms(raw).joined(separator: ", ").prefix(maxCharacters))
    }

    /// Exactly the terms that reach `--initial_prompt` — what `build` keeps after budgeting (F265).
    ///
    /// Separate from `build` because two callers need the *list*, not the joined string: `build`
    /// itself, and `isPromptEcho`, which may only judge a transcript against terms the model was
    /// actually given. Whisper cannot regurgitate a term it never saw, so matching against a
    /// trimmed-out term can only delete real speech.
    static func promptedTerms(_ raw: [String]) -> [String] {
        var kept: [String] = []
        for term in terms(raw) {
            // `continue`, not `break`: one term that does not fit must not discard the terms after
            // it. A single pasted CJK line can exceed the whole budget by itself (the Add box splits
            // only on "," and newline, so 、/，-punctuated text arrives as one term), and because
            // the store sorts alphabetically such a term can land first — with `break` that returned
            // an empty prompt and reinstated the whole-vocabulary loss this ticket exists to fix.
            // `MeetingStore.promptSafeTerms` skips for the same reason.
            if estimatedTokenCount(of: kept + [term]) > promptTokenBudget { continue }
            kept.append(term)
        }
        return kept
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
        // `promptedTerms`, not `terms`: only what actually reached `--initial_prompt` can be echoed
        // back. Judging against a budget-trimmed term cannot catch an echo — the model never saw it
        // — and can only delete real speech, because the caller sets the transcript to "" (F265).
        let normalized = promptedTerms(rawTerms).map(normalizedForEcho).filter { !$0.isEmpty }
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

    /// A no-speech probability at or above which a clip is treated as silence/noise rather than
    /// speech. Mirrors `TranscriptQuality`'s silence gate and Whisper's own `no_speech_threshold`.
    private static let echoSilenceNoSpeechThreshold = 0.6

    /// Whether a dictation result should be discarded as a prompt echo.
    ///
    /// Text shape alone (`isPromptEcho`) can't distinguish "the user genuinely dictated two
    /// adjacent vocabulary terms" from "Whisper regurgitated the prompt on a silent clip" — so
    /// dropping on text alone silently deletes real speech. Prompt echoes are a *silence/noise*
    /// artifact, so we require acoustic corroboration: drop only when the text has the echo shape
    /// **and** Whisper reports the clip was likely non-speech. When no acoustic signal is available
    /// (`nil`), fail safe and keep the text — never silently delete what might be real speech.
    public static func shouldDropAsPromptEcho(
        _ transcript: String,
        terms rawTerms: [String],
        noSpeechProb: Double?
    ) -> Bool {
        guard let noSpeechProb, noSpeechProb >= echoSilenceNoSpeechThreshold else { return false }
        return isPromptEcho(transcript, terms: rawTerms)
    }

    /// Lowercased, alphanumerics-only (punctuation/spaces removed; CJK letters kept), so
    /// "Acme, Q3" and "acme q3." compare equal.
    private static func normalizedForEcho(_ text: String) -> String {
        String(text.lowercased().unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(Character.init))
    }
}
