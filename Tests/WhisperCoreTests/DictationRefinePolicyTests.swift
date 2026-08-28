import Foundation
import Testing
@testable import WhisperCore

@Test("Empty and whitespace-only text is skipped")
func skipsEmptyText() {
    #expect(DictationRefinePolicy.decision(for: "") == .skip)
    #expect(DictationRefinePolicy.decision(for: "   \n ") == .skip)
}

@Test("Budget is 1.2s + 30ms per word, capped at 2.5s (constants measured against the real model)")
func budgetScalesWithWordCount() {
    // 10 words → 1200 + 300 = 1500 ms
    let ten = Array(repeating: "word", count: 10).joined(separator: " ")
    #expect(DictationRefinePolicy.decision(for: ten) == .attempt(budget: .milliseconds(1_500)))
    // 50 words → 1200 + 1500 = 2700 ms → capped to 2500 ms
    let fifty = Array(repeating: "word", count: 50).joined(separator: " ")
    #expect(DictationRefinePolicy.decision(for: fifty) == .attempt(budget: .milliseconds(2_500)))
}

@Test("Text longer than 60 words is skipped — it would nearly always miss the budget")
func skipsLongDictations() {
    let sixty = Array(repeating: "word", count: 60).joined(separator: " ")
    let sixtyOne = Array(repeating: "word", count: 61).joined(separator: " ")
    #expect(DictationRefinePolicy.decision(for: sixty) != .skip)
    #expect(DictationRefinePolicy.decision(for: sixtyOne) == .skip)
}

@Test("Majority-CJK text counts words as ceil(non-whitespace characters / 2)")
func cjkWordCounting() {
    // 48 CJK characters → 24 effective words → 1200 + 720 = 1920 ms
    let mandarin = String(repeating: "我们今天开会讨论那个方案", count: 4)
    #expect(DictationRefinePolicy.effectiveWordCount(of: mandarin) == 24)
    #expect(DictationRefinePolicy.decision(for: mandarin)
        == .attempt(budget: .milliseconds(1_200 + 24 * 30)))
    // Mostly-English text with one CJK term stays space-counted (F41 parity via TranscriptLanguage).
    #expect(DictationRefinePolicy.effectiveWordCount(of: "ship the 方案 tomorrow") == 4)
}
