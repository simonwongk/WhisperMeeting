import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F541 — the transcript card asked "was this transcript hand-edited?" up to eleven times per render,
// and every answer re-rendered the whole transcript through `TranscriptFormatter.timestamped` to
// compare it with the stored text. The Read view then re-ran the whole quality review each time the
// detail view above it rendered. Both are now remembered per value and recomputed only when the
// value changes.
//
// Counted through seams, never timed: how often the formatter or the review runs is a property of
// the code, and how long it takes is a property of the host.

@MainActor
private func makeModel() -> AppModel {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TranscriptRenderMemoTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(
        at: root.appendingPathComponent("Recordings", isDirectory: true),
        withIntermediateDirectories: true
    )
    let defaults = UserDefaults(suiteName: "WhisperMeet.TranscriptRenderMemoTests.\(UUID().uuidString)")!
    return AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
}

private func line(_ text: String, _ start: Double, avgLogprob: Double? = nil) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: start + 1.5, text: text, avgLogprob: avgLogprob)
}

private let lecture = (0..<40).map { line("Line \($0) of the lecture.", Double($0) * 2) }

/// A completed meeting whose stored text is the formatter's rendering of its lines — one nobody has
/// hand-edited.
@MainActor
private func storeMeeting(_ model: AppModel, segments: [TranscriptSegment] = lecture) -> UUID {
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id,
        title: "Lecture",
        status: .completed,
        transcriptText: TranscriptFormatter.timestamped(segments),
        languageCode: "en",
        segments: segments,
        transcriptNormalized: true
    ))
    return id
}

@MainActor
private func isEdited(_ model: AppModel, _ id: UUID) throws -> Bool {
    model.store.isTranscriptEdited(try #require(model.store.meeting(id: id)))
}

@MainActor
@Test("Asking whether a transcript was hand-edited formats it once per change, however often a render asks (F541)")
func editedCheckFormatsOncePerChange() throws {
    let model = makeModel()
    let id = storeMeeting(model)
    var formats = 0
    model.store.transcriptEditCheck = { text, segments in
        formats += 1
        return TranscriptFormatter.isEdited(transcriptText: text, segments: segments)
    }

    // One render's worth of asking, at the rate the transcript card asked before F541: nine reads of
    // its own, each on the record fetched fresh from the store as the body fetches it, plus the two
    // gates it asks the model for.
    func render() throws {
        for _ in 0..<9 { _ = try isEdited(model, id) }
        _ = model.lineRemovalBlockedReason(for: id)
        _ = model.lineRemovalBlockedReason(for: id)
    }

    try render(); try render(); try render()
    #expect(try isEdited(model, id) == false)
    #expect(formats == 1)

    // A Notes keystroke or a clock tick changes neither the text nor the lines: nothing to format.
    model.store.editNotes(id: id, text: "agenda")
    try render()
    #expect(formats == 1)

    // A keystroke in the Edit view is a change — seen at once, and formatted once more.
    model.store.editTranscript(id: id, text: TranscriptFormatter.timestamped(lecture) + " (fixed)")
    try render(); try render()
    #expect(try isEdited(model, id) == true)
    #expect(model.lineRemovalBlockedReason(for: id) != nil)
    #expect(formats == 2)

    // Typing the original back is not an edit.
    model.store.editTranscript(id: id, text: TranscriptFormatter.timestamped(lecture))
    try render()
    #expect(try isEdited(model, id) == false)
    #expect(model.lineRemovalBlockedReason(for: id) == nil)
    #expect(formats == 3)
}

@MainActor
@Test("The remembered answer follows a deleted line, its undo, and an equal record read back from disk (F541)")
func editedCheckFollowsEveryChange() throws {
    let model = makeModel()
    let id = storeMeeting(model)
    var formats = 0
    model.store.transcriptEditCheck = { text, segments in
        formats += 1
        return TranscriptFormatter.isEdited(transcriptText: text, segments: segments)
    }

    // Deleting a line rebuilds the text from the remaining lines, so the transcript is still not
    // edited — and the line count the answer came from is the new one.
    let removal = try #require(model.removeTranscriptLines(at: [0], from: id))
    #expect(try isEdited(model, id) == false)
    #expect(model.store.meeting(id: id)?.segments.count == lecture.count - 1)
    #expect(model.undoTranscriptLineRemoval(removal))
    #expect(try isEdited(model, id) == false)
    #expect(model.store.meeting(id: id)?.segments.count == lecture.count)

    model.store.editTranscript(id: id, text: "Rewritten by hand.")
    #expect(try isEdited(model, id) == true)
    let checksSoFar = formats

    // The same record decoded again holds equal values in different storage — what a reload gives.
    // Equal is equal: the answer is reused rather than formatted again.
    let stored = try #require(model.store.meeting(id: id))
    let decoded = try JSONDecoder().decode(MeetingRecord.self, from: JSONEncoder().encode(stored))
    #expect(model.store.isTranscriptEdited(decoded) == true)
    #expect(model.store.isTranscriptEdited(decoded) == true)
    #expect(formats == checksSoFar)
}

@MainActor
@Test("The Read view's quality review runs once per list of lines, not once per render of the view above it (F541)")
func reviewRunsOncePerSegmentList() {
    let memo = LastValueMemo<TranscriptReviewOverlay.Input, TranscriptReviewOverlay>()
    var reviews = 0
    func overlay(_ segments: [TranscriptSegment], edited: Bool) -> TranscriptReviewOverlay {
        memo.value(for: TranscriptReviewOverlay.Input(segments: segments, isEdited: edited)) { input in
            TranscriptReviewOverlay(input) { segments in
                reviews += 1
                return TranscriptQuality.review(segments)
            }
        }
    }
    // Line 2 is the one Whisper was unsure of (below its -1.0 log-probability threshold).
    let lines = [
        line("Good morning.", 0, avgLogprob: -0.2),
        line("Welcome back.", 2, avgLogprob: -0.3),
        line("Kestral quarterly.", 4, avgLogprob: -1.6),
        line("Let us begin.", 6, avgLogprob: -0.2),
    ]

    for _ in 0..<10 { _ = overlay(lines, edited: false) }
    #expect(reviews == 1)
    #expect(overlay(lines, edited: false).flagsByIndex.keys.sorted() == [2])
    #expect(overlay(lines, edited: false).report.flagged.map(\.index) == [2])

    // A hand-edited transcript shows no flags, and needs no review to know it.
    #expect(overlay(lines, edited: true).flagsByIndex.isEmpty)
    #expect(overlay(lines, edited: true).report.flagged.isEmpty)
    #expect(reviews == 1)

    // A deleted line is a new list: reviewed again, and the flag moves to the line's new index.
    let withoutFirst = Array(lines.dropFirst())
    #expect(overlay(withoutFirst, edited: false).flagsByIndex.keys.sorted() == [1])
    #expect(reviews == 2)
    for _ in 0..<10 { _ = overlay(withoutFirst, edited: false) }
    #expect(reviews == 2)
}

// The Read view is `PlayableTranscriptView`, which this target cannot render (F174's standing
// reason), and its initializer runs on every render of the detail view above it. So the wiring is
// asserted on `ContentView`'s source, comments stripped first (F285).
@Test("The Read view reaches its quality review only through the memo, and no view formats a transcript to test for edits (F541)")
func readViewReviewsThroughTheMemo() throws {
    // Booleans first, so a failure prints the sentence rather than the whole file.
    let contentView = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let callsTheReviewDirectly = contentView.contains("TranscriptQuality.review(")
    let readsTheReviewThroughTheMemo = contentView.contains("reviewMemo.value(for: TranscriptReviewOverlay.Input(")
    #expect(!callsTheReviewDirectly, """
        ContentView calls the quality review directly. PlayableTranscriptView's initializer runs on every \
        render of the detail view above it, so a review there re-runs over the whole transcript each time. \
        Read it through `reviewMemo` and `TranscriptReviewOverlay` instead.
        """)
    #expect(readsTheReviewThroughTheMemo)

    // Every edited-check in the app goes through `MeetingStore.isTranscriptEdited(_:)`, which
    // remembers its answer. Derived over the whole target so a new view cannot quietly call the
    // formatter's comparison from its body.
    var offenders: [String] = []
    for url in try SourceAssertion.swiftFileURLs(under: "Sources/WhisperMeet")
    where url.lastPathComponent != "MeetingStore.swift" {
        let path = url.path.replacingOccurrences(of: SourceAssertion.repositoryRoot.path + "/", with: "")
        for line in try SourceAssertion.uncommentedLines(path) where line.text.contains("TranscriptFormatter.isEdited(") {
            offenders.append("\(path):\(line.number)")
        }
    }
    #expect(offenders.isEmpty, "Call `store.isTranscriptEdited(_:)`, which remembers its answer: \(offenders)")
}
