import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F536 — Improve ▸ Correct Toward Vocabulary… ran the whole pass synchronously on the main actor
// (about 136 s at the 5,000-term cap, the app not responding) and could not be stopped. It now runs
// through `AppModel.proposeGlossaryCorrections(for:)`, off the main actor, with progress and Cancel.

@MainActor
private func makeModel(_ tag: String) throws -> (AppModel, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F536-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: "F536.\(UUID().uuidString)")!
    return (AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults), root)
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

/// Polls `condition` on the main actor against the wall clock, with a cap far above any real wait.
@MainActor
private func waitUntil(_ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private final class PassProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var ranOnMainThread: Bool?
    var sawMainThread: Bool? { lock.lock(); defer { lock.unlock() }; return ranOnMainThread }
    func record(isMain: Bool) { lock.lock(); ranOnMainThread = isMain; lock.unlock() }
}

@MainActor
@Test("Correct Toward Vocabulary finds Chinese mishearings through the app, and applies them in place (F536)")
func chineseCorrectionsThroughTheApp() async throws {
    let (model, root) = try makeModel("chinese")
    defer { try? FileManager.default.removeItem(at: root) }
    model.cjkWordSegmenter = dictionarySegmenterForApp(["明天", "下午", "三点", "请", "来", "开会", "讨论", "预算", "这个", "集群"])
    model.store.addVocabulary(["张经理", "预算", "Kubernetes"])
    let id = addMeeting(model, lines: ["对，张经里", "明天下午三点请张经里来开会", "讨论预算", "这个Kubernets集群"])

    let proposals = try #require(await model.proposeGlossaryCorrections(for: id))

    let expected: [GlossaryCorrection] = [
        GlossaryCorrection(segmentIndex: 0, from: "张经里", to: "张经理"),
        GlossaryCorrection(segmentIndex: 1, from: "张经里", to: "张经理"),
        GlossaryCorrection(segmentIndex: 3, from: "Kubernets", to: "Kubernetes"),
    ]
    #expect(proposals == expected)
    model.applyGlossaryCorrections(proposals, to: id)
    let lines = try #require(model.store.meeting(id: id)).segments.map(\.text)
    let applied: [String] = ["对，张经理", "明天下午三点请张经理来开会", "讨论预算", "这个Kubernetes集群"]
    #expect(lines == applied)
    #expect(model.glossaryCorrectionRun == nil)
}

/// The independent review's probe (rev-G, M-1): eight ordinary sentences against a vocabulary of the
/// common Chinese shapes — surname + title, word + one-character suffix — and one real mishearing.
/// A window matching two of a three-character term's characters in place was proposed for seven of
/// the eight ordinary lines (王经理 → 张经理, 王老师 → 李老师, 数据集 → 数据库 …), pre-ticked.
private let reviewVocabulary = ["客户端", "数据库", "张经理", "会议室", "总经理", "李老师", "产品经理", "路线图"]
private let reviewLines = [
    "我跟客户说了一下", "数据集已经准备好了", "王经理明天来", "我们在会议上讨论", "副总经理也同意",
    "王老师布置了作业", "项目经理负责这个", "路线不对", "明天下午三点请张经里来开会",
]
/// NLTokenizer's segmentation of those lines, as the review recorded it, pinned.
private let reviewDictionary: Set<String> = [
    "我", "跟", "客户", "说", "了", "一下", "数据", "集", "已经", "准备", "好", "王", "经理", "明天", "来",
    "我们", "在", "会议", "上", "讨论", "副", "总经理", "也", "同意", "老师", "布置", "作业", "项目", "负责",
    "这个", "路线", "不", "对", "下午", "三点", "请", "开会",
]

@MainActor
@Test("Ordinary Chinese words are not proposed toward a term they differ from in sound; the mishearing still is (F536)")
func ordinaryChineseWordsAreNotProposed() async throws {
    let (model, root) = try makeModel("homophones")
    defer { try? FileManager.default.removeItem(at: root) }
    model.cjkWordSegmenter = dictionarySegmenterForApp(reviewDictionary)
    model.store.addVocabulary(reviewVocabulary)
    let id = addMeeting(model, lines: reviewLines)

    let proposals = try #require(await model.proposeGlossaryCorrections(for: id))

    let wrong = proposals.filter { $0.segmentIndex != 8 }.map { "\($0.from) → \($0.to)" }
    #expect(wrong.isEmpty, "proposed for an ordinary line: \(wrong)")
    #expect(proposals.contains(GlossaryCorrection(segmentIndex: 8, from: "张经里", to: "张经理")))
}

@MainActor
@Test("The pass runs off the main actor, shows its progress, and Cancel stops it with no proposals (F536)")
func passRunsInTheBackgroundAndCancels() async throws {
    let (model, root) = try makeModel("cancel")
    defer { try? FileManager.default.removeItem(at: root) }
    model.store.addVocabulary(["Kubernetes"])
    let id = addMeeting(model, lines: ["we deployed cooper netties today"])
    let probe = PassProbe()
    model.glossaryCorrectionPass = { _, isCancelled, progress in
        probe.record(isMain: Thread.isMainThread)
        progress(0.5)
        // Stands in for a long pass: runs until the user cancels (capped, so a broken Cancel fails
        // the test instead of hanging it).
        let deadline = Date().addingTimeInterval(30)
        while !isCancelled(), Date() < deadline { usleep(1_000) }
        return [GlossaryCorrection(segmentIndex: 0, from: "cooper netties", to: "Kubernetes")]
    }

    let pass = Task { await model.proposeGlossaryCorrections(for: id) }
    let showedProgress = await waitUntil { model.glossaryCorrectionRun?.fractionDone == 0.5 }
    try #require(showedProgress, "the status line never showed the pass's progress")
    #expect(model.glossaryCorrectionRun?.meetingID == id)
    // The main actor is free while the pass runs — this test is running on it — and a second request
    // is refused rather than starting a second pass.
    #expect(await model.proposeGlossaryCorrections(for: id) == nil)

    model.cancelGlossaryCorrections()
    let result = await pass.value

    #expect(result == nil, "a cancelled pass must not present proposals")
    #expect(model.glossaryCorrectionRun == nil)
    #expect(probe.sawMainThread == false)
}

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return opened }
    func open() { lock.lock(); opened = true; lock.unlock() }
}

@MainActor
@Test("A transcript changed while the pass ran gets no proposals, so none can land on the wrong line (F536)")
func changedTranscriptDiscardsThePass() async throws {
    let (model, root) = try makeModel("stale")
    defer { try? FileManager.default.removeItem(at: root) }
    model.store.addVocabulary(["Kestrel"])
    // The review's probe (rev-G, F-a): a line removed while the pass runs shifts every index after it,
    // and the user's ticked proposal for one line then rewrote the line they had left unticked.
    let id = addMeeting(model, lines: ["um um", "the Kestrol release is ready", "Kestrol (a bird name) is a quote, keep it"])
    let gate = Gate()
    let real = model.glossaryCorrectionPass
    model.glossaryCorrectionPass = { input, isCancelled, progress in
        let result = real(input, isCancelled, progress)
        let deadline = Date().addingTimeInterval(30)
        while !gate.isOpen, Date() < deadline { usleep(1_000) }
        return result
    }

    let pass = Task { await model.proposeGlossaryCorrections(for: id) }
    let running = await waitUntil { model.glossaryCorrectionRun != nil }
    try #require(running, "the pass never started")
    let removal = model.removeTranscriptLines(at: IndexSet([0]), from: id)
    try #require(removal != nil, "the premise: a line can be removed while the pass runs")
    let afterRemoval = try #require(model.store.meeting(id: id)).segments
    gate.open()
    let result = await pass.value

    #expect(result == nil, "proposals computed over the old lines must not be offered")
    #expect(model.alertMessage?.contains("changed") == true)
    #expect(model.store.meeting(id: id)?.segments == afterRemoval)
}

// MARK: - One review at a time (rev-G F-b) and the Chinese backstop

@Test("A result arriving while a review is open waits for it, and each set is its own sheet (F536)")
func reviewsQueueInsteadOfReplacingAnOpenSheet() {
    var queue = ProposalReviewQueue()
    let rules = ProposalReview(proposals: [GlossaryCorrection(segmentIndex: 0, from: "Jon", to: "Jonathan")], source: .replacementRules)
    let vocabulary = ProposalReview(proposals: [GlossaryCorrection(segmentIndex: 1, from: "张经里", to: "张经理")], source: .vocabulary)

    queue.present(rules)
    // Correct Toward Vocabulary finishes in the background while the rules' sheet is open.
    queue.present(vocabulary)
    #expect(queue.current == rules, "an open review was replaced under its ticks")
    #expect(queue.waiting == [vocabulary])

    queue.close()
    #expect(queue.current == nil)
    queue.advance()
    #expect(queue.current == vocabulary)
    #expect(queue.waiting.isEmpty)
    #expect(rules.id != vocabulary.id)
}

@Test("Chinese near-misses from Correct Toward Vocabulary arrive unticked; other proposals as before (F536)")
func chineseNearMissesArriveUnticked() {
    let proposals = [
        GlossaryCorrection(segmentIndex: 0, from: "张经里", to: "张经理"),
        GlossaryCorrection(segmentIndex: 1, from: "Kubernets", to: "Kubernetes"),
        GlossaryCorrection(segmentIndex: 2, from: "王经理", to: "张经理"),
    ]
    let vocabulary = ProposalReview(proposals: proposals, source: .vocabulary)
    #expect(vocabulary.preselected(touching: [2]) == [1])
    // The user's own rules and the local model's corrections keep F245's rule alone.
    let rules = ProposalReview(proposals: proposals, source: .replacementRules)
    #expect(rules.preselected(touching: [2]) == [0, 1])
}

// MARK: - The menu item and status line (ContentView cannot be rendered in this target — F174)

@Test("Review sheets are presented one set at a time through the queue (F536)")
func reviewSheetIsKeyedBySet() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let keyedBySet = source.contains("get: { proposalReviews.current }")
    #expect(keyedBySet)
    let advancesOnDismiss = source.contains("onDismiss: { proposalReviews.advance() }")
    #expect(advancesOnDismiss)
    let presentations = source.components(separatedBy: "proposalReviews.present(ProposalReview(").count - 1
    #expect(presentations == 4, "Correct Toward Vocabulary, Apply Replacement Rules and both Correct with Local AI paths")
    let bareProposalState = source.contains("glossaryProposals")
    #expect(!bareProposalState)
}

@Test("Correct Toward Vocabulary goes through the background pass and its status line has Cancel (F536)")
func menuUsesTheBackgroundPass() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let callsThePass = source.contains("await model.proposeGlossaryCorrections(for: meetingID)")
    #expect(callsThePass)
    let callsTheOldSyncPass = source.contains("model.glossaryCorrections(for:")
    #expect(!callsTheOldSyncPass)
    let showsProgress = source.contains("ProgressView(value: run.fractionDone)")
    #expect(showsProgress)
    let offersCancel = source.contains("model.cancelGlossaryCorrections()")
    #expect(offersCancel)
    // The review sheet no longer re-checks every row against every term on each render.
    let rowRechecks = source.contains("GlossaryReviewDefaults.touchesProtectedTerm(proposal")
    #expect(!rowRechecks)
}

/// Greedy longest match over a small dictionary, other letters one character each — a fixed
/// segmentation so the test does not depend on this Mac's NLTokenizer dictionary.
private func dictionarySegmenterForApp(_ dictionary: Set<String>) -> CJKWordEvidence.Segmenter {
    let longest = dictionary.map(\.count).max() ?? 1
    return { text in
        var ranges: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index].isLetter || text[index].isNumber else {
                index = text.index(after: index)
                continue
            }
            var end = text.index(after: index)
            for length in stride(from: longest, to: 1, by: -1) {
                if let candidate = text.index(index, offsetBy: length, limitedBy: text.endIndex),
                   dictionary.contains(String(text[index..<candidate])) {
                    end = candidate
                    break
                }
            }
            ranges.append(index..<end)
            index = end
        }
        return ranges
    }
}
