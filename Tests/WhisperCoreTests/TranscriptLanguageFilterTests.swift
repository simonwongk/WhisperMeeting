import Foundation
import Testing
@testable import WhisperCore

// F424 — an English lecture recorded from the room also transcribes the Mandarin side-conversation
// of the students beside the Mac. The user asked for a way to drop those lines as a group. Picking
// them is language-by-line, and a line's language is judged by WORDS, not characters: an English
// word is five letters and a Chinese word is one or two characters, so counting characters calls
// "我们用 flash card 来复习" English.

private func line(_ text: String, _ start: Double? = 0, _ end: Double? = 1) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

@Test("A line's language is the one most of its words are in (F424)")
func aLineIsClassifiedByWords() {
    #expect(TranscriptLanguage.ofLine("So FDI is basically if the company has operations.") == .english)
    #expect(TranscriptLanguage.ofLine("黑皮拉梅是，是他妈是身材好，就差不多。") == .chinese)
    // Code-switching stays with the language of the sentence, not of the borrowed term.
    #expect(TranscriptLanguage.ofLine("我们用 flash card 来复习。") == .chinese)
    #expect(TranscriptLanguage.ofLine("We use 模型 today, don't we?") == .english)
    // Punctuation is not a word: the exhibit's `操！` is Mandarin, not a tie.
    #expect(TranscriptLanguage.ofLine("操！") == .chinese)
}

@Test("A line with no words, or an exact tie, has no language and is never picked (F424)")
func unscorableLinesHaveNoLanguage() {
    #expect(TranscriptLanguage.ofLine("…") == nil)
    #expect(TranscriptLanguage.ofLine("2026, 70, 3.5") == nil)
    #expect(TranscriptLanguage.ofLine("OK 好") == nil)
}

@Test("The lines picked are exactly those in the other language (F424)")
func theOtherLanguagesLinesArePicked() {
    let segments = [
        line("So FDI is basically if the company has operations."),
        line("别笑。"),
        line("That it controls in another country."),
        line("真是很别扭。"),
        line("2026"),
        line("We use 模型 today."),
    ]
    #expect(TranscriptLanguageFilter.indices(notIn: .english, segments: segments) == [1, 3])
    #expect(TranscriptLanguageFilter.indices(notIn: .chinese, segments: segments) == [0, 2, 5])
}

@Test("The meeting's language comes from its stored code, else from most of its lines (F424)")
func theMeetingLanguageIsResolved() {
    let mostlyMandarin = [line("我们下周一有个小测验。"), line("对。"), line("OK, fine.")]
    #expect(TranscriptLanguageFilter.meetingLanguage(languageCode: "en", segments: mostlyMandarin) == .english)
    #expect(TranscriptLanguageFilter.meetingLanguage(languageCode: "zh", segments: []) == .chinese)
    #expect(TranscriptLanguageFilter.meetingLanguage(languageCode: "zh-CN", segments: []) == .chinese)
    #expect(TranscriptLanguageFilter.meetingLanguage(languageCode: nil, segments: mostlyMandarin) == .chinese)
    #expect(TranscriptLanguageFilter.meetingLanguage(languageCode: nil, segments: [line("…")]) == nil)
    #expect(TranscriptLanguage.english.displayName == "English")
    #expect(TranscriptLanguage.chinese.displayName == "Mandarin")
}
