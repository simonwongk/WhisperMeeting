import Foundation
import Testing
@testable import WhisperCore

// F536 — Correct Toward Vocabulary split segments on ASCII whitespace only, so a Chinese sentence was
// one "word": a short segment was proposed to be replaced wholesale, a mishearing inside an ordinary
// sentence was never found, and a term already in the segment was "corrected" to itself. The three
// shapes below are the finding's own probe cases.

private func seg(_ text: String) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: 0, end: 1, text: text)
}

@Test("A short Chinese segment proposes only the misheard span, not the whole line (F536)")
func chineseProposalIsTheMisheardSpanOnly() {
    let segments = [seg("对，张经里")]
    let corrections = GlossaryCorrector.corrections(vocabulary: ["张经理"], segments: segments)
    #expect(corrections == [GlossaryCorrection(segmentIndex: 0, from: "张经里", to: "张经理")])
    // Applying it keeps "对，" — the old whole-segment proposal deleted it.
    #expect(GlossaryCorrector.apply(corrections, to: segments)[0].text == "对，张经理")
}

@Test("A mishearing inside an ordinary Chinese sentence is found (F536)")
func chineseMishearingInsideASentenceIsFound() {
    let segments = [seg("明天下午三点请张经里来开会")]
    let corrections = GlossaryCorrector.corrections(vocabulary: ["张经理"], segments: segments)
    // Not 请张经, the window one character to the left, which shares 张经 only as a subsequence.
    #expect(corrections == [GlossaryCorrection(segmentIndex: 0, from: "张经里", to: "张经理")])
}

@Test("A Chinese term already in the segment proposes nothing (F536)")
func chineseTermAlreadyPresentIsCorrect() {
    #expect(GlossaryCorrector.corrections(vocabulary: ["预算"], segments: [seg("讨论预算")]).isEmpty)
    #expect(GlossaryCorrector.corrections(vocabulary: ["张经理"], segments: [seg("我跟张经理说了，张经里也在")]).isEmpty)
}

@Test("A two-character term is not matched by every word sharing one character with it (F536)")
func twoCharacterTermNeedsMoreThanHalf() {
    // At exactly half, 预算 would be proposed for 计算 (calculate) and 预计 (expect).
    #expect(GlossaryCorrector.corrections(vocabulary: ["预算"], segments: [seg("我们计算一下预计的时间")]).isEmpty)
}

@Test("A Latin term written against Chinese proposes only the Latin word (F536)")
func latinTermGluedToChinese() {
    let segments = [seg("这个Kubernets集群要升级")]
    let corrections = GlossaryCorrector.corrections(vocabulary: ["Kubernetes"], segments: segments)
    #expect(corrections == [GlossaryCorrection(segmentIndex: 0, from: "Kubernets", to: "Kubernetes")])
    #expect(GlossaryCorrector.apply(corrections, to: segments)[0].text == "这个Kubernetes集群要升级")
    // Already correct when glued, too — this used to propose the whole run → "Kubernetes".
    #expect(GlossaryCorrector.corrections(vocabulary: ["Kubernetes"], segments: [seg("这个Kubernetes集群")]).isEmpty)
}

@Test("A Chinese window that cuts through a word is not proposed (F536 with F594's evidence)")
func chineseWindowCuttingAWordIsNotProposed() {
    // 会议纪 matches 会议室 position for position in two of three characters, and cuts 纪要.
    let segments = [seg("整理会议纪要")]
    let bySegmenter = CJKWordEvidence(segmenter: dictionarySegmenter(["整理", "会议", "纪要"]))
    #expect(GlossaryCorrector.corrections(vocabulary: ["会议室"], segments: segments, evidence: bySegmenter).isEmpty)
    let byVocabulary = CJKWordEvidence(knownTerms: ["会议室", "会议纪要"])
    #expect(GlossaryCorrector.corrections(vocabulary: ["会议室", "会议纪要"], segments: segments, evidence: byVocabulary).isEmpty)
}

@Test("A proposal is applied exactly where it was proposed (F536)")
func chineseProposalAppliesWhereProposed() {
    // The first 张经里 sits inside the vocabulary term 张经里路 (a street), so it is not the one
    // proposed; the application must reach the second as well.
    let evidence = CJKWordEvidence(knownTerms: ["张经理", "张经里路"])
    let segments = [seg("在张经里路见到张经里")]
    let corrections = GlossaryCorrector.corrections(vocabulary: ["张经理"], segments: segments, evidence: evidence)
    #expect(corrections == [GlossaryCorrection(segmentIndex: 0, from: "张经里", to: "张经理")])
    #expect(GlossaryCorrector.apply(corrections, to: segments, evidence: evidence)[0].text == "在张经里路见到张经理")
}

@Test("The pass reports progress to completion and returns nil once cancelled (F536)")
func passReportsProgressAndStops() {
    let segments = (0..<40).map { seg("对，张经里 \($0)") }
    let seen = FractionLog()
    let finished = GlossaryCorrector.corrections(
        vocabulary: ["张经理"], segments: segments, evidence: .none,
        isCancelled: { false }, progress: { seen.append($0) }
    )
    #expect(finished?.count == 40)
    #expect(seen.values.max() == 1)

    let cancelled = GlossaryCorrector.corrections(
        vocabulary: ["张经理"], segments: segments, evidence: .none,
        isCancelled: { true }, progress: { _ in }
    )
    #expect(cancelled == nil)
}

private final class FractionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func append(_ value: Double) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return stored }
}
