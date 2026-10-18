import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F816, round 2 (the review of lane U, findings 3 and 4).
//
// Finding 3: Keep Together into a vocabulary at its 5,000-term limit came back as a bare false; the
// sheet greyed the button and nothing said why. The outcome now carries the store's own limit
// sentence, and the sheet shows it under the row.
//
// Finding 4: a row inside a kept word is unticked and disabled, but Select All still counted its
// place, which can never be ticked, so the button read Select All for good and Deselect All could not
// be reached from it. The kept rows are passed to the rule as not the page's.

@MainActor
private func makeModel() throws -> (AppModel, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F816r2-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    return (model, root)
}

@Test("Keep Together into a full vocabulary says why, in the store's own words (F816, round 2)")
@MainActor
func keepTogetherIntoAFullVocabularySaysWhy() throws {
    let (model, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let filler = (0..<MeetingStore.maxStoredVocabularyTerms).map { "term\($0)" }
    _ = model.store.addVocabulary(filler)
    try #require(model.store.vocabulary.count == MeetingStore.maxStoredVocabularyTerms)

    let outcome = model.keepTogether("会议纪要")

    let expected = try #require(VocabularyAddition(refusedAtLimit: 1, refusedTerms: ["会议纪要"]).limitSentence)
    #expect(outcome == .refused(expected), "\(outcome)")
    #expect(!model.store.vocabulary.contains("会议纪要"))
}

@Test("The sheet shows a refused Keep Together's reason under the row (F816, round 2)")
func reviewSheetShowsTheKeepTogetherRefusal() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(source.contains("if case let .refused(reason) = keepTogether(word)"))
    #expect(source.contains("keepRefused[word] = reason"))
    #expect(source.contains("ForEach(words.compactMap { keepRefused[$0] }, id: \\.self) { reason in"))
}

@Test("Select All turns into Deselect All on a page holding a kept row, and back (F816, round 2)")
func selectAllTogglesBesideAKeptRow() {
    let rows = [
        GlossaryCorrection(segmentIndex: 0, from: "会议", to: "会议室", proposedLine: "整理会议纪要"),
        GlossaryCorrection(segmentIndex: 1, from: "会议", to: "会议室", proposedLine: "明天开会议"),
    ]
    let review = ProposalReview(proposals: rows, source: .replacementRules)
    let page = review.pages[0]
    let kept: Set<Int> = [0]   // row 0 sits inside the kept 会议纪要

    let all = review.toggledAll([], on: page, excluding: kept)
    #expect(all == [1], "Select All ticked a kept row, or missed the other")
    #expect(review.allTicked(all, on: page, excluding: kept), "the button still reads Select All")
    #expect(review.toggledAll(all, on: page, excluding: kept).isEmpty, "Deselect All did not clear the page")
    // Without kept rows the rule is unchanged.
    #expect(review.toggledAll([], on: page) == [0, 1])
    #expect(!review.allTicked([1], on: page))
}
