import Foundation
import Testing
@testable import WhisperCore

@Test("Empty and whitespace-only text is skipped")
func skipsEmptyText() {
    #expect(DictationRefinePolicy.decision(for: "") == .skip)
    #expect(DictationRefinePolicy.decision(for: "   \n ") == .skip)
}

@Test("Polish falls back to raw promptly when it misses the measured warm-model budget (F206)")
func budgetScalesWithWordCount() {
    // 10 words → 800 + 200 = 1000 ms. The current warm 8B helper completes the
    // production requests in 520–690 ms; this keeps a modest margin without making
    // a quick dictation wait at the former 1.2–2.5 s ceiling.
    let ten = Array(repeating: "word", count: 10).joined(separator: " ")
    #expect(DictationRefinePolicy.decision(for: ten) == .attempt(budget: .milliseconds(1_000)))
    // 50 words → 800 + 1000 = 1800 ms → capped to 1500 ms
    let fifty = Array(repeating: "word", count: 50).joined(separator: " ")
    #expect(DictationRefinePolicy.decision(for: fifty) == .attempt(budget: .milliseconds(1_500)))
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
        == .attempt(budget: .milliseconds(800 + 24 * 20)))
    // Mostly-English text with one CJK term stays space-counted (F41 parity via TranscriptLanguage).
    #expect(DictationRefinePolicy.effectiveWordCount(of: "ship the 方案 tomorrow") == 4)
}
