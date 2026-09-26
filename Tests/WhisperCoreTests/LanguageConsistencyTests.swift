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
    // A Mandarin sentence carrying English loanwords is still Mandarin: each loanword is ONE token
    // (F296, F468), so 8 CJK tokens outvote 3 Latin-run tokens ("bug", "fix", "merge") — matching
    // the Python helper's `detected_language_code`, which has called this sentence "zh" since F296.
    #expect(TranscriptLanguage.dominant(of: "这个 bug 已经 fix 了，可以 merge 了。") == .chinese)
    // A mostly-English sentence that mentions one Chinese place name stays English (F41 parity).
    #expect(TranscriptLanguage.dominant(of: "Let's meet in 北京 next week to review.") == .english)
    #expect(TranscriptLanguage.dominant(of: "") == nil)
}

// F468 — rather than restate expected labels by hand in both languages' test suites (which is
// exactly how `dominant`'s character rule and `_cjk_is_majority`'s token rule drifted apart in the
// first place after F296), this asks the installed `python3` for `detected_language_code`'s own
// answer on each vector and compares Swift's answer to it directly. A future change to either side
// that is not mirrored in the other fails here, without either file asserting a literal that could
// itself go stale.
@Test("Swift's dominant-script rule agrees with Python's detected_language_code on every vector (F296, F468)")
func swiftLanguageMajorityMatchesThePythonHelper() throws {
    let vectors = [
        "帮我把今天的会议纪要发给团队。",
        "Can you send me the quarterly report by Friday?",
        "请把这个报告发给张经理，然后通知团队 ASAP。",
        "这个 bug 已经 fix 了，可以 merge 了。",
        "Let's meet in 北京 next week to review.",
        "我们的 deadline 是这个星期五。",
        "帮我 schedule 一个 meeting，明天下午。",
        "请 review 一下",
        "Let's meet in 北京 and then 上海 next week",
        "The 太极 workshop runs on Tuesday in the main hall",
        "我们讨论了太极拳的历史和哲学",
        "hello world",
        "don't stop believing",
        "！？…",
        "123 456",
    ]

    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // WhisperCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repository root
    let helper = repositoryRoot.appendingPathComponent("Scripts/qwen_transcribe.py")

    let workDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("F468-language-parity-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDir) }
    let inputURL = workDir.appendingPathComponent("vectors.json")
    let outputURL = workDir.appendingPathComponent("labels.json")
    try JSONEncoder().encode(vectors).write(to: inputURL)

    let program = """
    import importlib.util, json
    spec = importlib.util.spec_from_file_location("qwen_transcribe", \(String(reflecting: helper.path)))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    with open(\(String(reflecting: inputURL.path)), encoding="utf-8") as handle:
        vectors = json.load(handle)
    labels = [module.detected_language_code(v) for v in vectors]
    with open(\(String(reflecting: outputURL.path)), "w", encoding="utf-8") as handle:
        json.dump(labels, handle)
    """
    let pipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", program]
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let errData = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, Comment(rawValue: String(decoding: errData, as: UTF8.self)))

    let pythonLabels = try JSONDecoder().decode([String].self, from: Data(contentsOf: outputURL))
    #expect(pythonLabels.count == vectors.count)
    for (vector, label) in zip(vectors, pythonLabels) {
        let expected: TranscriptLanguage = label == "zh" ? .chinese : .english
        #expect(
            TranscriptLanguage.dominant(of: vector) == expected,
            "\"\(vector)\" — python's detected_language_code says \(label)"
        )
    }
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

// MARK: - Summary language/script advisory (F467 Part 2)

@Test("A summary that translates a Chinese transcript into English is flagged (F467)")
func summaryTranslationIsFlagged() {
    let transcript = "我們決定新版本在十月十五號發佈，前提是測試全部通過。"
    let summary = MeetingSummary(
        summary: "We decided to release the new version on October 15, provided all tests pass.",
        keyPoints: [], actionItems: []
    )
    let warning = LanguageConsistency.summaryMismatchWarning(transcript: transcript, summary: summary)
    #expect(warning?.contains("English") == true)
    #expect(warning?.contains("transcript is unchanged") == true)
}

@Test("A summary that returns Simplified for a Traditional transcript is flagged (F467)")
func summaryScriptConversionIsFlagged() {
    let transcript = "我們決定這個價格給客戶優惠。"
    let summary = MeetingSummary(summary: "我们决定这个价格给客户优惠。", keyPoints: [], actionItems: [])
    let warning = LanguageConsistency.summaryMismatchWarning(transcript: transcript, summary: summary)
    #expect(warning?.contains("Simplified") == true)
    #expect(warning?.contains("Traditional") == true)
}

@Test("A summary in the transcript's own language and script is not flagged (F467)")
func matchingSummaryIsNotFlagged() {
    #expect(LanguageConsistency.summaryMismatchWarning(
        transcript: "We should ship on Friday.",
        summary: MeetingSummary(summary: "The team agreed to ship on Friday.", keyPoints: ["Ship Friday"], actionItems: [])
    ) == nil)
    #expect(LanguageConsistency.summaryMismatchWarning(
        transcript: "我們決定這個價格給客戶優惠。",
        summary: MeetingSummary(summary: "我們決定給客戶優惠。", keyPoints: [], actionItems: [])
    ) == nil)
    // Neither side has scorable text — nothing to compare.
    #expect(LanguageConsistency.summaryMismatchWarning(
        transcript: "", summary: MeetingSummary(summary: "", keyPoints: [], actionItems: [])
    ) == nil)
}
