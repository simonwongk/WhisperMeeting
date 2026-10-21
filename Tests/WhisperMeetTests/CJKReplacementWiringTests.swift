import Foundation
import NaturalLanguage
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F594 — the app gives the replacement matchers their Chinese word boundaries: NLTokenizer's
// segmentation through the injectable `cjkWordSegmenter` seam (F47 shape), and the stored
// vocabulary as known terms. These drive the app-level calls the Improve menu makes.

@MainActor
private func makeModel(root: URL) throws -> AppModel {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: testSuiteName())!
    return AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
}

@MainActor
private func addMeeting(_ model: AppModel, lines: [String]) -> UUID {
    let segments = lines.enumerated().map {
        TranscriptSegment(speaker: nil, start: Double($0.offset), end: Double($0.offset + 1), text: $0.element)
    }
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "M", status: .completed,
        transcriptText: TranscriptFormatter.timestamped(segments), segments: segments
    ))
    return id
}

/// A fixed segmentation, so the assertion does not depend on this Mac's dictionary: 会议厅 whole,
/// 会议纪要 split — what NLTokenizer was measured to do.
private let pinnedSegmenter: CJKWordEvidence.Segmenter = { text in
    let words = ["整理", "会议厅", "会议", "纪要", "明天", "开", "我们", "在", "讨论"]
    var ranges: [Range<String.Index>] = []
    var index = text.startIndex
    outer: while index < text.endIndex {
        for word in words where text[index...].hasPrefix(word) {
            let end = text.index(index, offsetBy: word.count)
            ranges.append(index..<end)
            index = end
            continue outer
        }
        index = text.index(after: index)
    }
    return ranges
}

@MainActor
@Test("Apply Replacement Rules leaves a Chinese compound alone and fixes the word standing alone (F594)")
func replacementRulesRespectChineseWordsThroughAppModel() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F594-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try makeModel(root: root)
    model.cjkWordSegmenter = pinnedSegmenter
    model.store.addVocabulary(["会议纪要"])
    model.store.addReplacementRule(heard: "会议", preferred: "会议室")
    let id = addMeeting(model, lines: ["整理会议纪要", "我们在会议厅讨论", "整理会议纪要，明天开会议"])

    let proposals = try #require(await model.replacementRuleCorrections(for: id))
    // Line 0: 会议 is inside the vocabulary term 会议纪要. Line 1: inside the segmenter's 会议厅.
    // Line 2: proposed once, for the standalone 会议.
    #expect(proposals == [GlossaryCorrection(segmentIndex: 2, from: "会议", to: "会议室", proposedLine: "整理会议纪要，明天开会议")])

    model.applyGlossaryCorrections(proposals, to: id)
    let lines = try #require(model.store.meeting(id: id)).segments.map(\.text)
    let expected: [String] = ["整理会议纪要", "我们在会议厅讨论", "整理会议纪要，明天开会议室"]
    #expect(lines == expected)
}

@MainActor
@Test("Correct with Local AI fans a Chinese correction out only to genuine occurrences (F594)")
func localModelCorrectionsGetChineseWordBoundaries() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F594-llm-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try makeModel(root: root)
    model.cjkWordSegmenter = pinnedSegmenter
    model.store.addVocabulary(["会议纪要"])
    model.isCorrectionModelInstalled = { true }
    // The model fixed one 会议; the fan-out must not offer it for the 会议 inside 会议纪要 (the review
    // of F594 replaced this path's evidence with `.none` and every test still passed).
    model.proposeTranscriptCorrections = { _, _, _ in [TranscriptCorrection(from: "会议", to: "会议室")] }
    let id = addMeeting(model, lines: ["整理会议纪要", "明天开会议"])

    let proposals = await model.proposeLocalCorrections(for: id)

    #expect(proposals == [GlossaryCorrection(segmentIndex: 1, from: "会议", to: "会议室", proposedLine: "明天开会议")])
}

private final class LocalModelGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var entered = false
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return opened }
    var hasEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    func open() { lock.lock(); opened = true; lock.unlock() }
    func enter() { lock.lock(); entered = true; lock.unlock() }
}

@MainActor
@Test("A transcript changed while the local model read it gets no proposals (F536's guard, same hazard)")
func localModelCorrectionsDiscardAChangedTranscript() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F536-llm-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try makeModel(root: root)
    model.store.addVocabulary(["Kestrel"])
    model.isCorrectionModelInstalled = { true }
    let gate = LocalModelGate()
    model.proposeTranscriptCorrections = { _, _, _ in
        gate.enter()
        let deadline = SuspendingClock.now + .seconds(30)
        while !gate.isOpen, SuspendingClock.now < deadline { usleep(1_000) }
        return [TranscriptCorrection(from: "Kestrol", to: "Kestrel")]
    }
    let id = addMeeting(model, lines: ["um um", "the Kestrol release is ready", "Kestrol (a bird) is a quote"])

    let pass = Task { await model.proposeLocalCorrections(for: id) }
    let deadline = SuspendingClock.now + .seconds(30)
    while !gate.hasEntered, SuspendingClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    try #require(gate.hasEntered, "the model never started")
    try #require(model.removeTranscriptLines(at: IndexSet([0]), from: id) != nil)
    gate.open()

    #expect(await pass.value.isEmpty)
    #expect(model.alertMessage?.contains("changed") == true)
}

@MainActor
@Test("The app's default Chinese segmenter is NLTokenizer's, as ranges into the text it was given (F594)")
func defaultSegmenterIsNaturalLanguage() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F594-nl-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try makeModel(root: root)

    // Mixed scripts and a character outside the BMP, so a range carried by the wrong index
    // encoding would land on the wrong characters.
    let text = "整理会议纪要 😀 then Kubernetes集群，明天开会议。"
    // Derived from NLTokenizer here rather than restated, so the test does not encode this Mac's
    // dictionary — it checks that the app passes NLTokenizer's answer through unchanged.
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = text
    var expected: [String] = []
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
        expected.append(String(text[range]))
        return true
    }
    try #require(!expected.isEmpty)

    let fromSeam = model.cjkWordSegmenter(text).map { String(text[$0]) }
    #expect(fromSeam == expected)
    #expect(NaturalLanguageWordSegmenter.wordRanges(in: text).map { String(text[$0]) } == expected)
    #expect(model.cjkWordEvidence.knownTerms == model.store.vocabulary)
}

// F816 — NLTokenizer splits a phrasal compound (会议纪要 → 会议 | 纪要, and every one of 47 business
// compounds probed for F816), so a rule 会议 → 会议室 rewrote inside it unless the user had added
// the compound to the vocabulary. The user chose a "keep together" button beside such a row
// (2026-10-17): one click adds the longer word to the vocabulary, which protects later passes and
// dictation through the same known-term evidence (F594).

@MainActor
@Test("A rule row that rewrites inside a longer word offers to keep that word together, and one click protects later passes and dictation (F816)")
func keepTogetherProtectsTheLongerWord() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F816-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try makeModel(root: root)
    model.cjkWordSegmenter = pinnedSegmenter
    let rule = ReplacementRule(heard: "会议", preferred: "会议室")
    model.store.addReplacementRule(heard: rule.heard, preferred: rule.preferred)
    let id = addMeeting(model, lines: ["整理会议纪要", "明天开会议"])

    let rows = try #require(await model.replacementRuleCorrections(for: id))
    #expect(rows.map(\.from) == ["会议", "会议"])
    // The first 会议 is followed by 纪要 and preceded by 整理, both words of two characters, so
    // both readings are offered; the second is preceded by the one-character 开 and ends the line.
    let offers = await model.proposalLongerWords(rows, in: id)
    #expect(offers == [["会议纪要", "整理会议"], []])
    // Dictation applies the rule inside the compound before the click.
    #expect(ReplacementRuleMatcher.applied([rule], to: "整理会议纪要", evidence: model.cjkWordEvidence) == "整理会议室纪要")

    #expect(model.keepTogether("会议纪要") == .kept)
    #expect(model.store.vocabulary.contains("会议纪要"))
    // The next pass offers only the standalone 会议, and dictation leaves the compound alone.
    let after = try #require(await model.replacementRuleCorrections(for: id))
    #expect(after == [GlossaryCorrection(segmentIndex: 1, from: "会议", to: "会议室", proposedLine: "明天开会议")])
    #expect(ReplacementRuleMatcher.applied([rule], to: "整理会议纪要", evidence: model.cjkWordEvidence) == "整理会议纪要")
    // Kept already: still a success, nothing added twice.
    #expect(model.keepTogether("会议纪要") == .kept)
    #expect(model.store.vocabulary.filter { $0 == "会议纪要" }.count == 1)
}

@Test("The review sheet offers Keep Together beside a rule row, through the model (F816)")
func reviewSheetOffersKeepTogether() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(source.contains("longerWords: { await model.proposalLongerWords($0, in: meetingID) }"))
    #expect(source.contains("keepTogether: { model.keepTogether($0) }"))
    #expect(source.contains("Button(\"Keep \\(word) Together\")"))
    #expect(source.contains("guard review.source == .replacementRules"))
}

// F995 round 2 — with the app's own segmenter (NLTokenizer), not a recording of it. Which names it
// reads with the surname alone depends on this Mac's dictionary, so the test asks it and expects the
// guard for exactly those: every name whose surname stands alone gets no sound-alike row.
@Test("With the app's real segmenter, no three-character name whose surname stands alone gets a sound-alike row (F995)")
func realSegmenterProtectsThreeCharacterNames() {
    let segmenter = NaturalLanguageWordSegmenter.wordRanges
    // The review's misheard lines: each is the name with one character swapped for a sound-alike.
    let pairs: [(name: String, heard: String)] = [
        ("林宇轩", "林雨轩"), ("刘子豪", "刘子浩"), ("王梓涵", "王子涵"), ("郭佳琪", "郭佳奇"), ("杨雨桐", "杨雨彤"),
        ("徐静怡", "徐静宜"), ("陈奕迅", "陈义迅"), ("赵一诺", "赵依诺"), ("马化腾", "马华腾"), ("张伟明", "张伟民"),
    ]
    var protected = 0
    for pair in pairs {
        let words = segmenter(pair.name)
        let surnameAlone = words.contains { $0 == pair.name.startIndex..<pair.name.index(after: pair.name.startIndex) }
        guard surnameAlone else { continue }
        protected += 1
        let evidence = CJKWordEvidence(segmenter: segmenter, knownTerms: [pair.name])
        let rows = GlossaryCorrector.corrections(
            vocabulary: [pair.name],
            segments: [TranscriptSegment(speaker: nil, start: 0, end: 1, text: pair.heard + "明天来")],
            evidence: evidence
        )
        #expect(rows.isEmpty, "\(pair.heard) was proposed as \(pair.name)")
    }
    // The premise: this Mac's segmenter reads at least one of them with the surname alone.
    #expect(protected > 0, "the segmenter read no surname alone, so nothing was checked")
}
