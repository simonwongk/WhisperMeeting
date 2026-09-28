import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F605 — the Second Opinion sheet marked a row "Replaced" and disabled it whether or not anything
// was written: `applySecondOpinionSpan` returned nothing, so the sheet could not know. Three
// refusals write nothing — a transcript edited by hand since the comparison (F436), a read-only
// library, and a line that is no longer there — and each was said, if at all, by the window's root
// alert, which sits BEHIND the open sheet (the F539 mechanism). The user saw "Replaced", nothing
// had changed, and no message was visible. Replace now reports what it did; the sheet marks the
// row only on success and says a refusal in its own alert.

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

private let lines = [seg("Hello Jon", 0, 1), seg("second wrong", 1, 2), seg("third", 2, 3)]
private let otherEngine = TranscriptionResult(
    id: "x", text: "Hello Jon second right third", languageCode: "en", audioDuration: 3, confidence: nil,
    segments: [seg("Hello Jon", 0, 1), seg("second right", 1, 2), seg("third", 2, 3)]
)

@MainActor
private func makeComparedMeeting() async throws -> (AppModel, UUID, TranscriptComparisonSpan, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F605-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Recordings"), withIntermediateDirectories: true)
    let defaults = try #require(UserDefaults(suiteName: "F605.\(UUID().uuidString)"))
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "M", recordingPath: "Recordings/\(id.uuidString)/meeting.wav", status: .completed,
        transcriptText: TranscriptFormatter.timestamped(lines), segments: lines
    ))
    model.runTranscriptionEngineOverride = { _, _ in otherEngine }
    await model.computeSecondOpinion(id: id)
    let diverging = try #require(model.secondOpinionSpans?.first { $0.kind == .diverge })
    return (model, id, diverging, root)
}

@MainActor
@Test("Replace says it replaced the line only when it did (F605 control)")
func secondOpinionReplaceReportsSuccess() async throws {
    let (model, id, diverging, root) = try await makeComparedMeeting()
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(model.applySecondOpinionSpan(diverging, to: id) == .replaced)
    #expect(model.store.meeting(id: id)?.segments[1].text == "second right")
}

@MainActor
@Test("A Replace refused on an edited transcript reports the refusal to the sheet, not behind it (F605)")
func secondOpinionReplaceReportsTheEditRefusal() async throws {
    let edited = "00:00  Hello John — fixed by hand\n00:01  second wrong\n00:02  third"
    let (model, id, diverging, root) = try await makeComparedMeeting()
    defer { try? FileManager.default.removeItem(at: root) }
    model.store.editTranscript(id: id, text: edited)

    #expect(model.applySecondOpinionSpan(diverging, to: id) == .refused(AppModel.secondOpinionReplaceRefusedForEdits))
    #expect(model.store.meeting(id: id)?.transcriptText == edited, "the edits survive")
    #expect(model.alertMessage == nil, "the window's alert is behind the sheet; the sheet says it")
}

@MainActor
@Test("A Replace whose line is gone reports that nothing was written (F605)")
func secondOpinionReplaceReportsAMissingLine() async throws {
    let (model, id, diverging, root) = try await makeComparedMeeting()
    defer { try? FileManager.default.removeItem(at: root) }
    // Deleted after the comparison was made, before Replace was pressed.
    #expect(model.removeTranscriptLines(at: IndexSet(integer: 1), from: id) != nil)

    #expect(model.applySecondOpinionSpan(diverging, to: id) == .refused(AppModel.secondOpinionReplaceLineGone))
    let texts: [String]? = model.store.meeting(id: id)?.segments.map(\.text)
    #expect(texts == ["Hello Jon", "third"])
    #expect(model.alertMessage == nil)
}

@MainActor
@Test("A Replace in a read-only library reports the refusal to the sheet, and raises nothing behind it (F605)")
func secondOpinionReplaceReportsAReadOnlyLibrary() async throws {
    let (seedModel, id, diverging, root) = try await makeComparedMeeting()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = seedModel
    // Corrupt only the primary index: the reopened library loads from its backup, read-only, with
    // the meeting still in it (DegradedLibraryTests' `.recoveredFromBackup` shape).
    try Data("truncated-primary".utf8).write(to: root.appendingPathComponent("meetings.json"))
    let defaults = try #require(UserDefaults(suiteName: "F605ro.\(UUID().uuidString)"))
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    try #require(model.store.isDegraded)
    try #require(model.store.meeting(id: id) != nil, "the meeting is still there to be refused")

    #expect(model.applySecondOpinionSpan(diverging, to: id)
        == .refused(ReadOnlyLibraryNotice.actionRefused(AppModel.secondOpinionReplaceAction)))
    #expect(model.store.meeting(id: id)?.segments[1].text == "second wrong")
    #expect(model.alertMessage == nil)
    #expect(model.store.storageErrorMessage == nil, "the store's own refusal would also land behind the sheet")
}

// The sheet cannot be rendered here (F174's standing reason), so its wiring is checked in the source,
// comments stripped first (F285): a row is marked only on `.replaced`, a refusal goes to the sheet's
// OWN alert, and the Replace closure is still the model's.
@Test("The sheet marks a row Replaced only when Replace wrote it, and says a refusal in its own alert (F605)")
func secondOpinionSheetMarksOnlyWhatWasReplaced() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let start = try #require(source.range(of: "private struct SecondOpinionSheet"))
    let rest = source[start.upperBound...]
    let end = rest.range(of: "\nprivate struct ")?.lowerBound ?? rest.endIndex
    let sheet = String(rest[..<end])

    #expect(sheet.contains("case .replaced: replaced.insert(index)"), "marked only on success")
    #expect(sheet.components(separatedBy: "replaced.insert(").count == 2, "and nowhere else")
    #expect(sheet.contains("case let .refused(reason): replaceRefusal = reason"))
    #expect(sheet.contains(".alert(") && sheet.contains("Text(replaceRefusal"), "said inside the sheet")
    #expect(source.contains("onReplace: { span in model.applySecondOpinionSpan(span, to: meetingID) }"))
}
