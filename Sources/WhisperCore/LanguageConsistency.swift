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

extension WhisperLanguage {
    /// The language to pin a later pass over part of a meeting to, from the `requestedLanguage` the
    /// meeting stored (F471): the pin its own transcription ran under, or `.automatic` for a meeting
    /// that ran under Automatic, was transcribed before the field existed (nil), or names a language
    /// this build cannot pin — an unknown raw value is detected, never guessed at.
    ///
    /// This is the only thing a per-segment re-run may pin on. It is deliberately not derived from
    /// `languageCode`: under Automatic that is the detected majority language, and pinning it forces
    /// the majority language onto a minority-language line of a code-switched meeting — Whisper gets
    /// `--language Chinese`, Qwen's prompt gets `language Chinese`, and the line comes back in the
    /// wrong language with nothing said. That is the mistranslation this ticket is about.
    public init(storedRequestedLanguage raw: String?) {
        self = raw.flatMap(WhisperLanguage.init(rawValue:)) ?? .automatic
    }

    /// The language a meeting's transcript came back in, read back from the `languageCode` it stored
    /// (F471). Keys the re-run advisory only — never the re-run's pin, which is
    /// `init(storedRequestedLanguage:)` above — so a line that comes back in the other script is
    /// still reported for a meeting that was detected rather than pinned.
    ///
    /// The stored value is what the engine returned, spelled either way: Whisper has stored an ISO
    /// code ("en", "zh") or a name ("English", "Chinese"); Qwen's helper stores "en"/"zh". Both map,
    /// and which spelling means what is not read into — nothing here depends on it. Anything else —
    /// nil, empty, or a language this app does not offer — is `.automatic`, and the advisory stays
    /// silent.
    public init(storedLanguageCode code: String?) {
        switch code?.lowercased() {
        case "en", "english": self = .english
        case "zh", "chinese": self = .chinese
        default: self = .automatic
        }
    }
}

public enum LanguageConsistency {
    /// An advisory when a re-transcribed segment reads as the other language from the one its
    /// meeting's transcript came back in, or nil (F471).
    ///
    /// **Advisory, not a refusal, and deliberately so.** `meetingLanguage` is the language the
    /// transcript came back in (`languageCode`), whether the meeting was pinned or detected — not
    /// the re-run's pin, which is `requestedLanguage` and is `.automatic` for most meetings. Under
    /// a pin, a line that still comes back in the other script is one where the audio won over the
    /// pin; under Automatic the re-run detected for itself, and a line in the other script is a
    /// switch the audio really has or a misdetection over a short clip. Either way the user should
    /// look, and in a meeting that switches language it is the faithful reading — refusing would
    /// throw exactly those lines away. What this cannot catch is the opposite case, a model that
    /// obeyed a pin and translated; no script check can, because the translation reads as the
    /// pinned language. That is why the re-run pins only what the meeting's own run pinned.
    ///
    /// Worded without F32's "You selected …": nobody selected this language for this re-run, it
    /// came from the meeting.
    public static func segmentRerunWarning(meetingLanguage: WhisperLanguage, replacementText: String) -> String? {
        let expected: TranscriptLanguage
        switch meetingLanguage {
        case .automatic: return nil
        case .english: expected = .english
        case .chinese: expected = .chinese
        }
        guard let actual = TranscriptLanguage.dominant(of: replacementText), actual != expected else { return nil }
        return "The re-transcribed line reads as \(displayName(actual)), but this meeting was transcribed as "
            + "\(displayName(expected)). Check the new line against the audio — the recording is unchanged."
    }

    private static func displayName(_ language: TranscriptLanguage) -> String {
        language == .chinese ? "Mandarin" : "English"
    }

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
