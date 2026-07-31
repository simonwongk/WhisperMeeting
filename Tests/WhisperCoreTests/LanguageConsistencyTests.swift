import Foundation
import Testing
@testable import WhisperCore

// F32 — "original language only" enforcement on the Qwen path. Qwen3-ASR has no translation task
// (mlx-audio 0.3.1 `Qwen3ASR.generate` only sets a recognition-language prompt hint), so it cannot
// translate. What was missing was any assertion that the produced text's script matches the language
// the user pinned — so a forced/mis-detected wrong language, or a future upstream drift, would pass
// silently. `LanguageConsistency` is the structural net: it flags when an explicitly requested
// language disagrees with the transcript's dominant script. These tests are hermetic (no model); the
// real installed model is exercised separately over Scripts/bench/clips (recorded in the log).

// MARK: - Dominant-script detection (mirrors the helper's detected_language_code majority rule)

@Test("Dominant-script detection labels Mandarin as zh and English as en (F32)")
func dominantScriptDetection() {
    #expect(TranscriptLanguage.dominant(of: "帮我把今天的会议纪要发给团队。") == .chinese)
    #expect(TranscriptLanguage.dominant(of: "Can you send me the quarterly report by Friday?") == .english)
    // A CJK-majority sentence with an embedded English acronym is still Mandarin (cjk*2 > total).
    #expect(TranscriptLanguage.dominant(of: "请把这个报告发给张经理，然后通知团队 ASAP。") == .chinese)
    // Latin-majority code-switch resolves to English — matching the helper's rule, which counts
    // characters (English words carry more letters than the CJK count), not word intent (F41 parity).
    #expect(TranscriptLanguage.dominant(of: "这个 bug 已经 fix 了，可以 merge 了。") == .english)
    // A mostly-English sentence that mentions one Chinese place name stays English (F41 parity).
    #expect(TranscriptLanguage.dominant(of: "Let's meet in 北京 next week to review.") == .english)
    #expect(TranscriptLanguage.dominant(of: "") == nil)
}

// MARK: - Consistency guard

/// The headline regression: a Mandarin meeting transcribed under an explicit English selection would
/// come back as English text — the guard must flag that mismatch. Fails before F32 (no such check).
@Test("A Chinese-requested transcript that comes back English is flagged (F32)")
func chineseRequestedEnglishOutputIsFlagged() {
    let warning = LanguageConsistency.mismatchWarning(
        requested: .chinese,
        transcript: "Can you send me the quarterly report by Friday afternoon?"
    )
    #expect(warning != nil)
}

/// The inverse: an English selection that returns Mandarin text is also flagged.
@Test("An English-requested transcript that comes back Mandarin is flagged (F32)")
func englishRequestedChineseOutputIsFlagged() {
    let warning = LanguageConsistency.mismatchWarning(
        requested: .english,
        transcript: "帮我把今天的会议纪要发给团队。"
    )
    #expect(warning != nil)
}

/// A matching selection produces no warning, in either language.
@Test("A transcript matching the requested language is not flagged (F32)")
func matchingLanguageIsNotFlagged() {
    #expect(LanguageConsistency.mismatchWarning(requested: .chinese, transcript: "这个季度的销售数据看起来很不错。") == nil)
    #expect(LanguageConsistency.mismatchWarning(requested: .english, transcript: "The build is failing on the release step.") == nil)
}

/// Automatic selection makes no claim about the intended language, so it never flags — the model
/// detected the language from the audio and there is nothing to contradict it. (Stated as a known
/// limitation in the F32 log: the guard protects the explicit-selection path only.)
@Test("Automatic language selection is never flagged (F32)")
func automaticIsNeverFlagged() {
    #expect(LanguageConsistency.mismatchWarning(requested: .automatic, transcript: "帮我把今天的会议纪要发给团队。") == nil)
    #expect(LanguageConsistency.mismatchWarning(requested: .automatic, transcript: "Send the report by Friday.") == nil)
    // Empty text carries no signal either way.
    #expect(LanguageConsistency.mismatchWarning(requested: .chinese, transcript: "") == nil)
}
