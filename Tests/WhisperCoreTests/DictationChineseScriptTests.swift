import Foundation
import Testing
@testable import WhisperCore

// F847 — the user's decision of 2026-10-16: a "Chinese script" setting for dictation (As heard,
// Simplified, Traditional), defaulting to the Mac's preferred language, and dictation converts to it.

@Test("Whisper Turbo's Traditional replies for the quiet calibration clips come back Simplified (F847)")
func theCalibrationClipsComeBackSimplified() {
    // Whisper Turbo's own replies, from Wave 8 lane C's probe of F599's attenuated clips
    // (`.claude/wave8/gates/F847-probe.log`): zh1 at −10…−40 dB and zh3 at −10…−30 dB.
    let traditional = [
        "幫我把今天的會議記要發給團隊",
        "幫我把今天的會議紀要發給團隊",
        "請提醒我下午3點跟客戶開會",
    ]
    let simplified = [
        "帮我把今天的会议记要发给团队",
        "帮我把今天的会议纪要发给团队",
        "请提醒我下午3点跟客户开会",
    ]
    #expect(traditional.map { DictationChineseScript.simplified.converted($0) } == simplified)
    // What came back Simplified already is left exactly as it was.
    #expect(simplified.map { DictationChineseScript.simplified.converted($0) } == simplified)
}

@Test("Traditional converts the other way, As heard changes nothing, and Latin is never touched (F847)")
func eachSettingConvertsOnlyHan() {
    #expect(DictationChineseScript.traditional.converted("帮我把今天的会议纪要发给团队") == "幫我把今天的會議紀要發給團隊")
    #expect(DictationChineseScript.asHeard.converted("幫我把今天的會議記要") == "幫我把今天的會議記要")
    #expect(DictationChineseScript.simplified.converted("I'll ping 王老師 about the 作業 tonight.")
            == "I'll ping 王老师 about the 作业 tonight.")
    #expect(DictationChineseScript.traditional.converted("Can you send the report?") == "Can you send the report?")
}

@Test("The default follows the first Chinese language the Mac prefers (F847)")
func theDefaultFollowsTheMacsPreferredLanguage() {
    #expect(DictationChineseScript.preferred(byLanguages: ["zh-Hans-US", "en-US"]) == .simplified)
    #expect(DictationChineseScript.preferred(byLanguages: ["zh-Hant-TW"]) == .traditional)
    #expect(DictationChineseScript.preferred(byLanguages: ["zh-TW"]) == .traditional)
    #expect(DictationChineseScript.preferred(byLanguages: ["zh-HK"]) == .traditional)
    #expect(DictationChineseScript.preferred(byLanguages: ["zh-CN"]) == .simplified)
    // English first and Chinese second: the bilingual Mac this setting is for.
    #expect(DictationChineseScript.preferred(byLanguages: ["en-US", "zh-Hans-US"]) == .simplified)
    #expect(DictationChineseScript.preferred(byLanguages: ["en-GB", "fr-FR"]) == .asHeard)
    #expect(DictationChineseScript.preferred(byLanguages: []) == .asHeard)
}

@Test("This Mac's languages start the setting at Simplified: any Simplified entry wins over a Traditional one listed first (F847, the user's decision of 2026-10-17)")
func thisMacStartsAtSimplified() {
    // `defaults read -g AppleLanguages` on the user's Mac, 2026-10-17. Round 2 took the first Chinese
    // entry and gave Traditional (the round-2 review's C1); the user chose Simplified.
    #expect(DictationChineseScript.preferred(byLanguages: ["en-US", "zh-Hant-US", "zh-Hans-US"]) == .simplified)
    #expect(DictationChineseScript.preferred(byLanguages: ["zh-Hant-TW", "zh-CN"]) == .simplified)
    #expect(DictationChineseScript.preferred(byLanguages: ["en-US", "zh-SG"]) == .simplified)
    // Traditional only when no Simplified entry is listed at all.
    #expect(DictationChineseScript.preferred(byLanguages: ["en-US", "zh-Hant-US"]) == .traditional)
}

@Test("A vocabulary term keeps its own characters, in either script, whatever the setting (F847, the round-2 review's C2)")
func vocabularyTermsAreNotConverted() {
    // ICU writes the surname 范 as 範 and the surname 钟 as 鐘 in Traditional; a name the user
    // taught the app is kept as they wrote it.
    #expect(DictationChineseScript.traditional.converted("范总和钟经理明天来")
            == "範總和鐘經理明天來", "ICU's own conversion changed; the case below no longer shows why terms are kept")
    #expect(DictationChineseScript.traditional.converted("范总和钟经理明天来", keeping: ["范总", "钟经理"])
            == "范总和钟经理明天來")
    // A term stored in Traditional is kept in a Simplified dictation too.
    #expect(DictationChineseScript.simplified.converted("鍾經理說可以", keeping: ["鍾經理"]) == "鍾經理说可以")
    // A term heard in its other script's form is left as heard, not converted either way.
    #expect(DictationChineseScript.simplified.converted("範總明天來", keeping: ["范总"]) == "範總明天来")
    // Latin terms and empty terms change nothing.
    #expect(DictationChineseScript.traditional.converted("会议", keeping: ["Kubernetes", ""]) == "會議")
}

@Test("Text Whisper detected as Japanese is not converted (F847, the round-2 review's C3)")
func japaneseIsNotConverted() {
    #expect(DictationChineseScript.simplified.converted("東京で会議があります", languageCode: "ja") == "東京で会議があります")
    #expect(DictationChineseScript.traditional.converted("東京で会議があります", languageCode: "ja") == "東京で会議があります")
    #expect(DictationChineseScript.simplified.converted("東京會議", languageCode: "zh") == "东京会议")
    // A code-switched English dictation still has its Chinese words written in the chosen script.
    #expect(DictationChineseScript.simplified.converted("Send the 會議紀要", languageCode: "en") == "Send the 会议纪要")
}
