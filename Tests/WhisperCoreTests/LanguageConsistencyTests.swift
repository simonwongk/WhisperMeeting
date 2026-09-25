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

// F471 — a per-segment re-run pins its language only when the meeting's own transcription was
// pinned, which the meeting records as `requestedLanguage` (a `WhisperLanguage` raw value). The
// first version of this ticket read the pin off `languageCode` instead — and that is what the
// engine RETURNED: under Automatic, the default, it is only the detected majority language (Whisper
// detects once from the first 30 seconds; Qwen's helper takes the majority script of the whole
// text). So a minority-language line of a code-switched meeting was re-run with the majority
// language forced (`--language Chinese`, `language Chinese<asr_text>`) — the mistranslation Part 2
// of this ticket was about, in a new configuration.
@Test("A stored requested language pins the re-run only when it was a pin (F471)")
func storedRequestedLanguageMapsBackToAPinOrAutomatic() {
    #expect(WhisperLanguage(storedRequestedLanguage: WhisperLanguage.chinese.rawValue) == .chinese)
    #expect(WhisperLanguage(storedRequestedLanguage: WhisperLanguage.english.rawValue) == .english)
    #expect(WhisperLanguage(storedRequestedLanguage: WhisperLanguage.automatic.rawValue) == .automatic)
    // A meeting transcribed before the field was recorded: nothing is known about a pin, so none.
    #expect(WhisperLanguage(storedRequestedLanguage: nil) == .automatic)
    // A raw value this build cannot pin — a language a newer build offers — detects, never guesses.
    #expect(WhisperLanguage(storedRequestedLanguage: "japanese") == .automatic)
    #expect(WhisperLanguage(storedRequestedLanguage: "") == .automatic)
    // A language CODE is not a requested language. Feeding `languageCode` in here by mistake must
    // yield no pin — that is the whole reason the two fields are kept apart.
    #expect(WhisperLanguage(storedRequestedLanguage: "zh") == .automatic)
    #expect(WhisperLanguage(storedRequestedLanguage: "Chinese") == .automatic)
}

// The stored code keeps one job: keying the advisory that says when a re-run line came back in the
// other script from the transcript it joins. Both spellings map because both have been stored;
// nothing reads a pin out of which spelling it was.
@Test("A stored language code maps back to the language the transcript came back in (F471)")
func storedLanguageCodeMapsBackToTheTranscriptsLanguage() {
    #expect(WhisperLanguage(storedLanguageCode: "en") == .english)
    #expect(WhisperLanguage(storedLanguageCode: "English") == .english)
    #expect(WhisperLanguage(storedLanguageCode: "zh") == .chinese)
    #expect(WhisperLanguage(storedLanguageCode: "Chinese") == .chinese)
    #expect(WhisperLanguage(storedLanguageCode: "ZH") == .chinese)
    #expect(WhisperLanguage(storedLanguageCode: "ja") == .automatic)
    #expect(WhisperLanguage(storedLanguageCode: "") == .automatic)
    #expect(WhisperLanguage(storedLanguageCode: nil) == .automatic)
}

@Test("A re-run line in the meeting's other script gets an advisory that claims no user choice (F471)")
func segmentRerunAdvisoryNamesTheMeetingsLanguage() throws {
    let warning = try #require(LanguageConsistency.segmentRerunWarning(
        meetingLanguage: .chinese, replacementText: "We should ship on Friday."
    ))
    #expect(warning.contains("English"))
    #expect(warning.contains("Mandarin"))
    // The language came from the meeting, not from a selection the user made for this re-run, so
    // the F32 wording ("You selected …") would be a false attribution here.
    #expect(!warning.contains("You selected"))

    #expect(LanguageConsistency.segmentRerunWarning(meetingLanguage: .chinese, replacementText: "我们周五发布。") == nil)
    #expect(LanguageConsistency.segmentRerunWarning(meetingLanguage: .automatic, replacementText: "Hello.") == nil)
    #expect(LanguageConsistency.segmentRerunWarning(meetingLanguage: .english, replacementText: "  ") == nil)
}
