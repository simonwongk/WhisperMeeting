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
    #expect(traditional.map(DictationChineseScript.simplified.converted) == simplified)
    // What came back Simplified already is left exactly as it was.
    #expect(simplified.map(DictationChineseScript.simplified.converted) == simplified)
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
