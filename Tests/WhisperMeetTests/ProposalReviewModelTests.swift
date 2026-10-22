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
        // The third row is no first-name pair: since F1064 "Jon → Jonathan" would arrive unticked.
        proposals: [row(0, "Kestral", "Kestrel"), row(0, "Kestral", "Kestrol"), row(1, "Kubernets", "Kubernetes")],
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
    #expect(source.contains("selected = review.toggledAll(selected, on: review.pages[page], groups: groups, excluding: keptRows)"))
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

@Test("Rows for one place stay on one page even when a source lists them apart, as Correct with Local AI does (F818, round 2)")
func rowsForOnePlaceStayOnOnePageWhateverTheirOrder() {
    // The review of lane E, finding 5: the local model's rows come by correction, then by line, so
    // its two readings of one word were rows 199 and 201 and landed on different pages, where
    // neither page saw the other as its alternative.
    let unsorted: [GlossaryCorrection] = (0..<199).map { row($0 + 1, "w", "t") }
        + [row(0, "Kestral", "Kestrel"), row(500, "x", "y"), row(0, "Kestral", "Kestrol")]
    let review = ProposalReview(proposals: unsorted, source: .localModel)
    let kestral = review.proposals.indices.filter { review.proposals[$0].segmentIndex == 0 }
    #expect(kestral.count == 2)
    #expect(review.pages.filter { page in kestral.contains(where: page.contains) }.count == 1)
    // Line order, and each line's rows in the order the source gave them.
    #expect(review.proposals.map(\.segmentIndex) == review.proposals.map(\.segmentIndex).sorted())
    #expect(review.proposals.prefix(2).map(\.to) == ["Kestrel", "Kestrol"])
}

@Test("A place whose rows Select All may not tick is still one place: a hand-ticked sound-alike row counts as its tick (F966, round 2)")
func handTickedAlternativeCountsForItsPlace() {
    // The review of lane E, finding 7: places were built from the rows Select All may tick, so a
    // hand-ticked Chinese alternative was invisible and Select All ticked the other row of its place too.
    let mixed = ProposalReview(proposals: [row(0, "Kestrol", "Kestrel"), row(0, "Kestrol网关", "Kestrel网关")], source: .vocabulary)
    let groups = [0: 0, 1: 0]
    let handPicked = mixed.ticking(1, on: true, in: [0], groups: groups)
    #expect(handPicked == [1])
    #expect(mixed.allTicked(handPicked, groups: groups))
    #expect(mixed.toggledAll([], groups: groups) == [0])
}

@Test("The sheet checks each page when it is shown, ticks its rows then, allows nothing on it until then, and Apply says which pages it covers (F818, F966, round 3)")
func sheetChecksPageByPage() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    // Round 2 checked the whole review before anything could be ticked: 8 s at 3,000 rows and 41 s
    // at 15,000 with 5,000 terms (the second review of lane E). The user chose "check page by page"
    // on 2026-10-18: each page when shown, and Apply covers the pages checked.
    #expect(source.contains(".task(id: page) { await check(page) }"))
    #expect(!source.contains("loadReview()"))
    #expect(source.contains("selected.formUnion(review.preselected(touching: pageTouching, on: rows, groups: pageGroups))"))
    // Blocked until the page shown has been checked (round 2's finding 7 holds per page).
    #expect(source.contains(".disabled(!pageChecked || selected.isEmpty)"))
    #expect(source.contains(".disabled(!pageChecked || (review.selectableAll.isEmpty && selected.isEmpty))"))
    #expect(source.contains(".disabled(!pageChecked || keptWord(for: index) != nil)"))
    #expect(source.contains("ProposalReview.applyLabel(count: selected.count, checkedPages: checkedPages.count, pageCount: review.pages.count)"))
}

@Test("Apply names the pages it covers once a review has more than one (F818, round 3)")
func applyLabelNamesTheCheckedPages() {
    #expect(ProposalReview.applyLabel(count: 37, checkedPages: 2, pageCount: 15) == "Apply 37 changes on 2 checked pages")
    #expect(ProposalReview.applyLabel(count: 1, checkedPages: 1, pageCount: 15) == "Apply 1 change on 1 checked page")
    // One page is the whole review, and the button reads as it always did.
    #expect(ProposalReview.applyLabel(count: 3, checkedPages: 1, pageCount: 1) == "Apply 3 Corrections")
    #expect(ProposalReview.applyLabel(count: 1, checkedPages: 1, pageCount: 1) == "Apply 1 Correction")
}

@Test("A Correct Toward Vocabulary row in a line that already spells its term right arrives unticked; elsewhere a mishearing is ticked as before (F994, round 3)")
func rowsBesideTheirTermArriveUnticked() {
    // The second-round review of lane E: beside the right spelling the 0.75 bar cannot tell a
    // second person or product from a mishearing (Carla 0.8 is Carl's colleague, Kestrol 0.86 is
    // misheard), and these rows arrived ticked — one Apply wrote "Carl and Carl will review…". The
    // user chose, on 2026-10-18, to offer them unticked: nothing is renamed unless they tick it.
    let vocabulary = ["Carl", "Sara", "Brian", "Priya Raman", "GPT-4", "Postgres", "Kestrel"]
    let lines = [
        "Carl and Carla will sync", "Sara and Sarah agreed", "Brian and Bryan agreed",
        "Priya Raman and Priya Ramani agreed", "GPT-4 and GPT-4o differ", "Postgres or PostgreSQL",
        "the Kestrol launch moved",
    ]
    let segments = lines.map { TranscriptSegment(speaker: nil, start: 0, end: 1, text: $0) }
    let rows = GlossaryCorrector.proposing(GlossaryCorrector.corrections(vocabulary: vocabulary, segments: segments), on: segments)
    let review = ProposalReview(proposals: rows, source: .vocabulary)
    let shown = review.proposals.map { "\($0.from) → \($0.to)" }
    let beside = [
        "Carla → Carl", "Sarah → Sara", "Bryan → Brian", "Priya Ramani → Priya Raman", "GPT-4o → GPT-4",
        "PostgreSQL → Postgres",
    ]
    let pre = Set(review.preselected(touching: [], groups: [:]).map { shown[$0] })
    let afterSelectAll = Set(review.toggledAll([], groups: [:]).map { shown[$0] })
    for row in beside {
        // Still offered — one tick away — but neither preselected nor Select All's.
        #expect(shown.contains(row), "\(row) is no longer offered")
        #expect(!pre.contains(row), "\(row) arrived ticked")
        #expect(!afterSelectAll.contains(row), "Select All ticked \(row)")
    }
    #expect(review.besideTheirTerm == Set(shown.indices.filter { beside.contains(shown[$0]) }))
    // A mishearing in a line without its term is ticked as before. "Carla → Sara" — Carla in a line
    // without Sara — was too, until F1064: both are first names, so it now arrives unticked.
    #expect(pre.contains("Kestrol → Kestrel"))
    if shown.contains("Carla → Sara") { #expect(!pre.contains("Carla → Sara"), "a first name renamed in one click") }
    // From the other tools nothing changes: a rule is the user's own, a model's row is reviewed as before.
    #expect(ProposalReview(proposals: rows, source: .replacementRules).preselected(touching: []).count == rows.count)
    // The sheet says why such a row is unticked.
    let source = (try? SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")) ?? ""
    #expect(source.contains("} else if review.besideTheirTerm.contains(index) {"))
}

// F1064 — F1039's rules keep a row toward a name in a line without it when the window scores 0.8, writes the
// term's digits and is no function word: so Carla → Carl, Sarah → Sara and Bryan → Brian arrived ticked, and
// one Apply could rename a person the user never misheard. The user chose on 2026-10-22 that a row turning one
// common first name into another starts unticked. A mishearing toward a name is ticked as before.
@MainActor
@Test("A row turning one first name into another arrives unticked; a mishearing toward a name is still ticked (F1064)")
func firstNameToFirstNameRowsArriveUnticked() {
    let vocabulary = ["Carl", "Sara", "Brian", "Kestrel", "Priya Raman"]
    let lines = ["Carla will sync on Friday", "Sarah agreed with the plan", "Bryan agreed too",
                 "the Kestrol launch moved", "ask Pria Ramen about it"]
    let segments = lines.map { TranscriptSegment(speaker: nil, start: 0, end: 1, text: $0) }
    let rows = GlossaryCorrector.proposing(GlossaryCorrector.corrections(vocabulary: vocabulary, segments: segments), on: segments)
    let review = ProposalReview(proposals: rows, source: .vocabulary)
    let shown = review.proposals.map { "\($0.from) → \($0.to)" }
    let pre = Set(review.preselected(touching: [], groups: [:]).map { shown[$0] })
    let afterSelectAll = Set(review.toggledAll([], groups: [:]).map { shown[$0] })
    for row in ["Carla → Carl", "Sarah → Sara", "Bryan → Brian"] {
        #expect(shown.contains(row), "\(row) is no longer offered: \(shown)")
        #expect(!pre.contains(row), "\(row) arrived ticked")
        #expect(!afterSelectAll.contains(row), "Select All ticked \(row)")
    }
    for row in ["Kestrol → Kestrel", "Pria Ramen → Priya Raman"] {
        #expect(pre.contains(row), "\(row) — a mishearing — arrived unticked: \(shown)")
    }
}

@Test("The sheet says why a first-name row is unticked (F1064)")
func theSheetSaysWhyAFirstNameRowIsUnticked() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(source.contains("} else if review.renamesAPerson.contains(index) {"))
    #expect(source.contains("are both first names — this may rename a person"))
}
