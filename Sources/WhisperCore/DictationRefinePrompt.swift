import Foundation

/// System prompt for the dictation refine helper. Swift is the single source of truth for prompts
/// (the `LocalSummarizer`/`ClaudeSummarizer` precedent); the Python helper only applies the chat
/// template. Light touch by design decision (2026-08-28): the user's wording and order stay theirs.
public enum DictationRefinePrompt {
    /// The prompt for a dictation whose script is known (F244).
    ///
    /// On 2026-09-17 the F244 harness sent a Traditional dictation through refinement and got
    /// Simplified back — 個→个, 貨→货 — on ordinary business text. `DictationRefinePolicy` now
    /// refuses that, which makes refinement safe for a Traditional writer and useless for them:
    /// every refinement is rejected and the raw text pasted. Naming the script is what lets the
    /// model not convert in the first place. The script is read from the dictation itself
    /// (`ScriptDrift.form(of:)`), never from a setting or a guess, and nil names nothing.
    ///
    /// Appended after the language sentence, for the same reason that sentence is appended: the
    /// resident helper caches the prompt up to the common token prefix (F203), and a variation at
    /// the end costs a few tokens where one at the start would cost the whole cache.
    public static func system(languageCode: String?, script: ChineseScriptForm?) -> String {
        var prompt = system(languageCode: languageCode)
        guard languageCode == "zh", let script else { return prompt }
        switch script {
        case .traditional:
            prompt += " The input is written in Traditional Chinese characters; reply in Traditional Chinese characters and never convert them to Simplified."
        case .simplified:
            prompt += " The input is written in Simplified Chinese characters; reply in Simplified Chinese characters and never convert them to Traditional."
        }
        return prompt
    }

    public static func system(languageCode: String?) -> String {
        var prompt = """
        You clean up text that a person dictated by voice. Correct grammar, punctuation, \
        capitalization, and obvious speech-to-text mistakes, and remove filler words such as \
        "um", "uh", and "you know". Keep the speaker's wording, sentence order, and meaning \
        exactly: do not rephrase, do not summarize, do not add content, and do not answer the \
        text as if it were a question. Reply in the same language as the input; never translate. \
        Reply with ONLY the corrected text — no quotation marks around it, no explanation, no markdown.
        """
        switch languageCode {
        case "zh": prompt += " The input is Mandarin Chinese; reply only in Mandarin Chinese."
        case "en": prompt += " The input is English; reply only in English."
        default: break
        }
        return prompt
    }
}
