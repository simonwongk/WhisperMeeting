import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F966 — two rows for one occurrence are alternatives: one tick between them, and the Apply count is
// the number of places changed. F818 — a review of thousands of rows is shown a page at a time, a
// page ending where a line ends so alternatives are never split, with the rows on other pages counted.

private func row(_ segment: Int, _ from: String, _ to: String) -> GlossaryCorrection {
    GlossaryCorrection(segmentIndex: segment, from: from, to: to)
}

@Test("Ticking one of two rows for one place unticks the other, and Select All picks one per place (F966)")
func alternativesTakeOneTick() {
    let review = ProposalReview(
        proposals: [row(0, "Kestral", "Kestrel"), row(0, "Kestral", "Kestrol"), row(1, "Jon", "Jonathan")],
        source: .vocabulary
    )
    let groups = [0: 0, 1: 0]
    // Both arrive preselected by F245's rule; one place keeps the first.
    #expect(review.preselected(touching: [], groups: groups) == [0, 2])
    #expect(review.ticking(1, on: true, in: [0, 2], groups: groups) == [1, 2])
    #expect(review.ticking(1, on: false, in: [1, 2], groups: groups) == [2])
    #expect(review.ticking(2, on: true, in: [], groups: groups) == [2])
    // Select All keeps a hand-picked alternative and adds one for every other place.
    #expect(review.toggledAll([1], groups: groups) == [1, 2])
    #expect(review.toggledAll([], groups: groups) == [0, 2])
    #expect(review.allTicked([1, 2], groups: groups))
    #expect(review.toggledAll([1, 2], groups: groups) == [])
}

@Test("A long review is shown a page at a time, each page ending at the end of a line, and counts the rest (F818)")
func longReviewIsPaged() {
    // 167,128 rows on the synthetic 5,000-term corpus (F536) is what one sheet rendered.
    let perLine = 3
    let proposals: [GlossaryCorrection] = (0..<1_000).flatMap { segment in
        (0..<perLine).map { row(segment, "w\($0)", "t\($0)") }
    }
    let review = ProposalReview(proposals: proposals, source: .vocabulary)
    #expect(ProposalReview.pageSize == 200)
    // 200 is not a multiple of 3: each page runs to the end of the line it reaches, 201 rows.
    #expect(review.pages.first == 0..<201)
    #expect(review.pages.allSatisfy { $0.count >= 200 || $0 == review.pages.last })
    #expect(review.pages.map(\.count).reduce(0, +) == proposals.count)
    for (earlier, later) in zip(review.pages, review.pages.dropFirst()) {
        #expect(earlier.upperBound == later.lowerBound)
        #expect(proposals[earlier.upperBound - 1].segmentIndex != proposals[later.lowerBound].segmentIndex)
    }
    #expect(ProposalReview.pageLabel(review.pages[1], of: proposals.count) == "Rows 202–402 of 3,000")
    // Select All on a page ticks that page only, and keeps what other pages hold.
    let second = review.pages[1]
    let ticked = review.toggledAll([0], on: second, groups: [:])
    #expect(ticked == Set([0]).union(second))
    #expect(review.allTicked(ticked, on: second, groups: [:]))
    #expect(!review.allTicked(ticked, on: review.pages[0], groups: [:]))
    // A short review is one page, as before.
    let short = ProposalReview(proposals: Array(proposals.prefix(10)), source: .replacementRules)
    #expect(short.pages == [0..<10])
}

@Test("The review sheet ticks through the review's alternatives rule, marks a row's alternatives, and pages a long review (F966, F818)")
func reviewSheetUsesAlternativesAndPages() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(source.contains("selected = review.ticking(index, on: isOn, in: selected, groups: groups)"))
    #expect(source.contains("alternatives: { await model.proposalAlternatives($0, in: meetingID) }"))
    #expect(source.contains("ForEach(review.pages[page], id: \\.self)"))
    #expect(source.contains("ProposalReview.pageLabel(review.pages[page], of: proposals.count)"))
    #expect(source.contains("selected = review.toggledAll(selected, on: review.pages[page], groups: groups)"))
}

@MainActor
@Test("The app finds a review's alternatives off the main actor with the evidence it applies with (F966)")
func appFindsAlternatives() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProposalReviewModelTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = AppModel(
        store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: testSuiteName())!
    )
    let segments = [TranscriptSegment(speaker: nil, start: 0, end: 1, text: "the Kestral build")]
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "M", status: .completed,
        transcriptText: TranscriptFormatter.timestamped(segments), segments: segments
    ))
    let rows = [row(0, "Kestral", "Kestrel"), row(0, "Kestral", "Kestrol")]
    #expect(await model.proposalAlternatives(rows, in: id) == [0: 0, 1: 0])
}
