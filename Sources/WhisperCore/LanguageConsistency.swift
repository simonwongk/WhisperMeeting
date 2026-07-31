import Foundation

/// Post-transcription language checks supporting the "original language only, never translation"
/// invariant on the Qwen path (F32).
///
/// The *structural* guarantee is in the model, not here: Qwen3-ASR is transcription-only —
/// mlx-audio 0.3.1's `Qwen3ASR.generate(language:)` uses the language solely to build an ASR prompt
/// (`…/mlx_audio/stt/models/qwen3_asr/qwen3_asr.py:861`, `"…language {lang_name}<asr_text>"`) and
/// exposes no `translate` task, so translation cannot occur (verified empirically: forcing
/// `--language English` on a Mandarin clip still returns Mandarin text). This type does not add
/// structural enforcement; it is a lightweight **heuristic advisory** that runs after transcription
/// and changes nothing about the transcript or recording. It catches the residual risk — a
/// wrong-language *recognition* when the user pins a language the audio was not in, or a future
/// upstream change — by comparing the produced text's dominant script against the pinned language.
///
/// Scope and limits (see the F32 log): it only fires when the user has **explicitly** selected
/// English or Chinese. Under `.automatic` (the default) it cannot fire — the only label available is
/// the helper's own `detected_language_code`, which is derived from this same text by this same
/// majority rule, so cross-checking it would be circular. Auto-mode language fidelity therefore
/// rests on the model plus the real-clip corpus evidence, not on this check.
public enum TranscriptLanguage: Sendable, Equatable {
    case english
    case chinese

    /// The dominant script of a transcript, or `nil` when there is no scorable text. Mirrors the
    /// Qwen helper's `detected_language_code` majority rule (`Scripts/qwen_transcribe.py`): a
    /// transcript is Mandarin only when CJK ideographs (`U+3400…U+9FFF`) are the majority of
    /// non-whitespace characters — so a mostly-English sentence that mentions one Chinese term is
    /// still English (F41 parity), not zh.
    public static func dominant(of text: String) -> TranscriptLanguage? {
        var cjk = 0
        var total = 0
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace { continue }
            total += 1
            if scalar.value >= 0x3400 && scalar.value <= 0x9FFF {
                cjk += 1
            }
        }
        guard total > 0 else { return nil }
        return cjk * 2 > total ? .chinese : .english
    }
}

public enum LanguageConsistency {
    /// A plain-language advisory when an explicitly requested language disagrees with the
    /// transcript's dominant script (F32). Returns `nil` for `.automatic` (no user-stated intent to
    /// contradict — see the type doc), when the scripts match, or when the text is empty.
    public static func mismatchWarning(requested: WhisperLanguage, transcript: String) -> String? {
        let expected: TranscriptLanguage
        let requestedName: String
        switch requested {
        case .automatic:
            return nil
        case .english:
            expected = .english
            requestedName = "English"
        case .chinese:
            expected = .chinese
            requestedName = "Mandarin"
        }
        guard let actual = TranscriptLanguage.dominant(of: transcript), actual != expected else {
            return nil
        }
        let actualName = actual == .chinese ? "Mandarin" : "English"
        return "You selected \(requestedName), but this transcript reads as \(actualName). "
            + "The recording is unchanged — re-transcribe with the correct language if the audio was "
            + "\(requestedName)."
    }
}
