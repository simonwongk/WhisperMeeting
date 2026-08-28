import Foundation

/// System prompt for the dictation refine helper. Swift is the single source of truth for prompts
/// (the `LocalSummarizer`/`ClaudeSummarizer` precedent); the Python helper only applies the chat
/// template. Light touch by design decision (2026-08-28): the user's wording and order stay theirs.
public enum DictationRefinePrompt {
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
