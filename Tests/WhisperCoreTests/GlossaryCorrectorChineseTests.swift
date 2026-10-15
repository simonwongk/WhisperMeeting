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

@Test("A window that differs from the term in sound is not proposed, however many characters match (F536)")
func chineseWindowMustSoundLikeTheTerm() {
    // Two of three characters in place, but 王 (wang) is not 张 (zhang): a different person.
    #expect(GlossaryCorrector.corrections(vocabulary: ["张经理"], segments: [seg("王经理明天来")]).isEmpty)
    #expect(GlossaryCorrector.corrections(vocabulary: ["数据库"], segments: [seg("数据集已经准备好了")]).isEmpty)
    #expect(GlossaryCorrector.corrections(vocabulary: ["Q3预算"], segments: [seg("Q4预算还没批")]).isEmpty)
    var cache: [Character: String] = [:]
    #expect(MandarinSound.isHomophone("里", of: "理", cache: &cache))
    #expect(!MandarinSound.isHomophone("王", of: "张", cache: &cache))
    #expect(!MandarinSound.isHomophone("4", of: "3", cache: &cache))
}

@Test("A Chinese term already in the segment proposes nothing (F536)")
func chineseTermAlreadyPresentIsCorrect() {
    #expect(GlossaryCorrector.corrections(vocabulary: ["预算"], segments: [seg("讨论预算")]).isEmpty)
    #expect(GlossaryCorrector.corrections(vocabulary: ["张经理"], segments: [seg("我跟张经理说了，张经里也在")]).isEmpty)
}

@Test("A two-character term is not matched by every word sharing one character with it (F536)")
func twoCharacterTermNeedsMoreThanHalf() {
    // 计算 (calculate) and 预计 (expect) share one character with 预算, but the other does not sound
    // like the term's: ji is not yu, ji is not suan. Since F817 that sound is the whole test.
    #expect(GlossaryCorrector.corrections(vocabulary: ["预算"], segments: [seg("我们计算一下预计的时间")]).isEmpty)
}

@Test("A two-character term is proposed for a homophone mishearing of one character (F817)")
func twoCharacterHomophoneMishearingIsProposed() {
    let segments = [seg("明天的会意改到下午"), seg("我们周无见"), seg("这个预选不够")]
    let corrections = GlossaryCorrector.corrections(vocabulary: ["会议", "周五", "预算"], segments: segments)
    // 会意 (hui yi) and 周无 (zhou wu) read exactly as the terms do, tones aside. 预选 (yu xuan) does
    // not read as 预算 (yu suan), so it is not proposed: matching by sound is matching by sound.
    #expect(corrections == [
        GlossaryCorrection(segmentIndex: 0, from: "会意", to: "会议"),
        GlossaryCorrection(segmentIndex: 1, from: "周无", to: "周五"),
    ])
    #expect(GlossaryCorrector.apply(corrections, to: segments).map(\.text) == ["明天的会议改到下午", "我们周五见", "这个预选不够"])
}

@Test("A two-character window sharing no character with the term is not proposed, however alike it sounds (F817)")
func twoCharacterTermNeedsOneCharacterOfItsOwn() {
    // 攻势 (attack) reads gong shi exactly as 公式 (formula) does, and is a different word.
    #expect(GlossaryCorrector.corrections(vocabulary: ["公式"], segments: [seg("他们的攻势很猛")]).isEmpty)
}

@Test("A four-character term still needs more than half its characters in place; half is for two-character terms (F817)")
func fourCharacterTermNeedsMoreThanHalf() {
    // 时常 (often) reads shi chang like 市场 (market), and 精力 (energy) jing li like 经理 (manager):
    // two in place, two homophones, and both are other words. F817's first round lowered every
    // even-length term to half and proposed them; the review measured two right and two wrong new
    // four-character rows. Three in four, as F536 asked, still finds 产品经历 for 产品经理.
    let segments = [seg("我们时常分析数据"), seg("这个项目精力有限"), seg("产品经历了三次迭代")]
    let corrections = GlossaryCorrector.corrections(vocabulary: ["市场分析", "项目经理", "产品经理"], segments: segments)
    #expect(corrections == [GlossaryCorrection(segmentIndex: 2, from: "产品经历", to: "产品经理")])
}

@Test("A sound-alike window is never proposed for a two-character term that is a person's name: a surname and a given name the segmenter does not read as one word (F921)")
func soundAlikeWindowsAreNotProposedForNames() {
    // The Wave 5 review measured 张薇 → 张伟, 刘阳 → 刘洋, 王方 → 王芳, 黎明 → 李明 and 留洋 → 刘洋
    // among 15 wrong rows in 40 everyday sentences: other people, and other words, renamed. The
    // text cannot tell a mishearing of 张伟 from the person 张薇, so no row is made for a name at
    // all; NLTokenizer reads a two-character name as surname | given name (张 | 伟) and a word that
    // begins with a surname character whole (周五, 王国, 李子), which is how a name is told.
    let segmenter = dictionarySegmenter([
        "明天", "来", "开会", "出差", "负责", "财务", "黎明", "时分", "我们", "出发", "年轻", "留洋", "多年",
        "周五", "会议", "经理", "改到", "下午", "周无", "会意",
    ])
    let vocabulary = ["张伟", "刘洋", "王芳", "李明", "周五", "会议", "张经理"]
    let evidence = CJKWordEvidence(segmenter: segmenter, knownTerms: vocabulary)
    let segments = [
        seg("张薇明天来开会"), seg("刘阳出差了"), seg("王方负责财务"), seg("黎明时分我们出发"), seg("他年轻时留洋多年"),
        seg("我们周无见"), seg("明天的会意改到下午"), seg("对，张经里"),
    ]
    let corrections = GlossaryCorrector.corrections(vocabulary: vocabulary, segments: segments, evidence: evidence)
    // The words 周五 and 会议, and the title 张经理 (surname | 经理, a word), are proposed as before.
    #expect(corrections == [
        GlossaryCorrection(segmentIndex: 5, from: "周无", to: "周五"),
        GlossaryCorrection(segmentIndex: 6, from: "会意", to: "会议"),
        GlossaryCorrection(segmentIndex: 7, from: "张经里", to: "张经理"),
    ])
    // Without a segmenter nothing can tell a name from a word, and the rows are made as before.
    #expect(GlossaryCorrector.corrections(vocabulary: ["张伟"], segments: [seg("张薇明天来开会")])
        == [GlossaryCorrection(segmentIndex: 0, from: "张薇", to: "张伟")])
    // A term the segmenter reads whole is a word, whatever character it begins with.
    #expect(GlossaryCorrector.corrections(vocabulary: ["周五"], segments: [seg("我们周无见")], evidence: evidence)
        == [GlossaryCorrection(segmentIndex: 0, from: "周无", to: "周五")])
}

@Test("A row's sentence is the words around the place apply changes, cut at a space, marked where the line goes on (F817)")
func proposalContextIsTheChangedPlaceInItsSentence() {
    let chinese = GlossaryCorrection(segmentIndex: 0, from: "会意", to: "会议")
    #expect(GlossaryCorrector.context(of: chinese, in: "明天的会意改到下午")
        == ProposalContext(before: "明天的", match: "会意", after: "改到下午"))
    // Up to 24 characters either side, backed off to a space rather than through a word.
    let latin = GlossaryCorrection(segmentIndex: 0, from: "Kestrol", to: "Kestrel")
    #expect(GlossaryCorrector.context(of: latin, in: "We should ship the Kestrol build on Friday after the review")
        == ProposalContext(before: "We should ship the ", match: "Kestrol", after: " build on Friday after…"))
    #expect(GlossaryCorrector.context(of: latin, in: "One two three four five six seven eight Kestrol nine")
        == ProposalContext(before: "…five six seven eight ", match: "Kestrol", after: " nine"))
    // The place is apply's: not the "Kestrol" inside "Kestrols", and nothing where apply changes nothing.
    #expect(GlossaryCorrector.context(of: latin, in: "Kestrols and Kestrol")
        == ProposalContext(before: "Kestrols and ", match: "Kestrol", after: ""))
    #expect(GlossaryCorrector.context(of: latin, in: "nothing to change here") == nil)
}

@Test("A sheet's sentences worked out together are each row's own, with the line's evidence shared (F952)")
func proposalContextsAreEachRowsContext() {
    // 会议 inside the known term 会议纪要 is not a word of its own, and the segmenter keeps 会议厅
    // whole, so the row's place is the third 会议 — with the whole vocabulary as known terms, as the
    // app passes it. The segmenter splits 会议纪要 (会议 | 纪 | 要, as NLTokenizer does, F594), so
    // only the known term refuses its 会议: the narrowing `contexts` does is what is tested (the Wave
    // 6 review of lane T, mutant M-K, survived while the segmenter held 会议纪要 whole).
    // Typed separately: the CI runner's Swift 6.1 is weaker at inferring a mixed expression.
    let filler: [String] = (0..<500).map { "术语\($0)号" }
    let knownTerms: [String] = ["会议纪要", "Kestrel"] + filler
    let evidence = CJKWordEvidence(
        segmenter: dictionarySegmenter(["整理", "会议厅", "会议", "明天", "开"]), knownTerms: knownTerms
    )
    let segments = [
        TranscriptSegment(speaker: nil, start: 0, end: 1, text: "整理会议纪要，在会议厅，明天开会议"),
        TranscriptSegment(speaker: nil, start: 1, end: 2, text: "Zoë and Jon. Jon left."),
        TranscriptSegment(speaker: nil, start: 2, end: 3, text: "the Kestrol build"),
    ]
    let rows = [
        GlossaryCorrection(segmentIndex: 2, from: "Kestrol", to: "Kestrel"),
        GlossaryCorrection(segmentIndex: 0, from: "会议", to: "会议室"),
        GlossaryCorrection(segmentIndex: 1, from: "Jon", to: "Jonathan", characterOffset: 13),
        GlossaryCorrection(segmentIndex: 7, from: "Kestrol", to: "Kestrel"),   // a line that is gone
        GlossaryCorrection(segmentIndex: 2, from: "nowhere", to: "Kestrel"),   // nothing to change
    ]
    let together = GlossaryCorrector.contexts(of: rows, in: segments, evidence: evidence)
    let oneByOne: [ProposalContext?] = rows.map { row in
        segments.indices.contains(row.segmentIndex)
            ? GlossaryCorrector.context(of: row, in: segments[row.segmentIndex].text, evidence: evidence) : nil
    }
    #expect(together == oneByOne)
    #expect(together[1] == ProposalContext(before: "整理会议纪要，在会议厅，明天开", match: "会议", after: ""))
    #expect(together[2] == ProposalContext(before: "Zoë and Jon. ", match: "Jon", after: " left."))
    #expect(together[3] == nil && together[4] == nil)
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
    // 张经里 comes first and sounds like 张经理, but it sits inside the vocabulary term 张经里路 (a
    // street), where `apply` would never put it; the proposal is the later 张经礼. A different text,
    // so the check is visible: without it the first window would be proposed, and apply would find
    // no genuine 张经里 to change.
    let evidence = CJKWordEvidence(knownTerms: ["张经理", "张经里路"])
    let segments = [seg("在张经里路见到张经礼")]
    let corrections = GlossaryCorrector.corrections(vocabulary: ["张经理"], segments: segments, evidence: evidence)
    #expect(corrections == [GlossaryCorrection(segmentIndex: 0, from: "张经礼", to: "张经理")])
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
