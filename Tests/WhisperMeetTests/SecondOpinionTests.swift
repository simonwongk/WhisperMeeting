import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

@MainActor
private func makeModel() throws -> (AppModel, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SecondOpinion-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Recordings"), withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: testSuiteName())!
    return (AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults), root)
}

// F88 — a "second opinion" runs the OTHER engine on the same recording and compares, but must never
// overwrite the stored transcript; only an explicit per-span apply changes it.
@MainActor
@Test("Second opinion compares the other engine and leaves the stored transcript byte-for-byte intact (F88)")
func secondOpinionDoesNotMutateStoredTranscript() async throws {
    let (model, _) = try makeModel()
    let id = UUID()
    let stored = [seg("hello world", 0, 1), seg("second segment", 1, 2)]
    model.store.upsert(MeetingRecord(
        id: id, title: "M",
        recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed,
        transcriptText: TranscriptFormatter.timestamped(stored),
        segments: stored
    ))
    let before = model.store.meeting(id: id)?.transcriptText

    // The injected "other engine" disagrees on the second segment.
    model.runTranscriptionEngineOverride = { _, _ in
        TranscriptionResult(
            id: "x", text: "hello world second thing", languageCode: "en",
            audioDuration: 2, confidence: nil,
            segments: [seg("hello world", 0, 1), seg("second thing", 1, 2)]
        )
    }

    await model.computeSecondOpinion(id: id)

    #expect(model.secondOpinionSpans?.count == 2)
    #expect(model.secondOpinionSpans?.contains { $0.kind == .agree } == true)      // first segment
    #expect(model.secondOpinionSpans?.contains { $0.kind == .diverge } == true)    // second segment
    #expect(model.store.meeting(id: id)?.transcriptText == before)                 // never overwritten

    // Applying one span replaces only that segment's text, on explicit user action.
    if let diverge = model.secondOpinionSpans?.first(where: { $0.kind == .diverge }) {
        model.applySecondOpinionSpan(diverge, to: id)
    }
    #expect(model.store.meeting(id: id)?.segments[1].text == "second thing")
    #expect(model.store.meeting(id: id)?.segments[0].text == "hello world")        // untouched
}

// F472 — the other engine's boundaries sit a fraction of a second away from this transcript's, so
// every line after the first overlapped the other engine's previous sentence too. Pairing with the
// first overlap offered that sentence as the other reading, and Replace wrote it in: the same
// sentence twice, and the real line gone.
@MainActor
@Test("Replace writes the other engine's reading of the same line, not its previous sentence (F472)")
func secondOpinionReplaceWritesTheMatchingLine() async throws {
    let (model, _) = try makeModel()
    let id = UUID()
    let stored = [seg("We should ship on Friday.", 10.0, 13.2), seg("Then we review the numbrs.", 13.2, 18.0)]
    model.store.upsert(MeetingRecord(
        id: id, title: "M",
        recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed,
        transcriptText: TranscriptFormatter.timestamped(stored),
        segments: stored
    ))
    model.runTranscriptionEngineOverride = { _, _ in
        TranscriptionResult(
            id: "x", text: "We should ship on Friday. Then we review the numbers.", languageCode: "en",
            audioDuration: 18.1, confidence: nil,
            segments: [seg("We should ship on Friday.", 9.8, 13.3), seg("Then we review the numbers.", 13.3, 18.1)]
        )
    }

    await model.computeSecondOpinion(id: id)
    let diverging = try #require(model.secondOpinionSpans?.first { $0.kind == .diverge })
    model.applySecondOpinionSpan(diverging, to: id)

    #expect(model.store.meeting(id: id)?.segments.map(\.text) == [
        "We should ship on Friday.", "Then we review the numbers.",
    ])
}

// F574 — Second Opinion ran the other engine in whatever language Settings held when it was asked,
// not the one the meeting was transcribed in. Settings are for the next meeting: a meeting pinned to
// Mandarin got its second opinion under an English pin, and a pinned engine can come back with a
// translation, which the sheet then offers to Replace the Mandarin line with. The meeting's own
// request decides, as it does for a segment re-run (F471): its pin if it had one, else Automatic.
@MainActor
@Test("Second Opinion runs the other engine in the language the meeting asked for, never Settings' (F574)")
func secondOpinionRunsInTheMeetingsRequestedLanguage() async throws {
    final class SeenSelection: @unchecked Sendable { var value: MeetingTranscriptionSelection? }
    // nil is a meeting transcribed before the request was recorded: nothing is known about a pin.
    let cases: [(requested: String?, expected: WhisperLanguage)] = [
        (WhisperLanguage.chinese.rawValue, .chinese),
        (WhisperLanguage.automatic.rawValue, .automatic),
        (nil, .automatic),
    ]
    for (requested, expected) in cases {
        let label = Comment(rawValue: "requestedLanguage \(requested ?? "nil")")
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.selectedLanguage = .english   // chosen since, for the next meeting
        let id = UUID()
        let stored = [seg("我们明天开会", 0, 2)]
        model.store.upsert(MeetingRecord(
            id: id, title: "M", recordingPath: "Recordings/\(id.uuidString)/meeting.wav", status: .completed,
            transcriptText: TranscriptFormatter.timestamped(stored), languageCode: "zh", segments: stored,
            transcriptionEngine: .whisperLarge, requestedLanguage: requested
        ))
        let seen = SeenSelection()
        model.runTranscriptionEngineOverride = { selection, _ in
            seen.value = selection
            return TranscriptionResult(id: "x", text: "我们明天开会", languageCode: "zh", audioDuration: 2,
                                       confidence: nil, segments: [seg("我们明天开会", 0, 2)])
        }

        await model.computeSecondOpinion(id: id)

        #expect(seen.value == MeetingTranscriptionSelection(engine: .qwenBalanced, language: expected), label)
    }
}

// F572 — the other engine split this line in two. Pairing with its larger piece offered only the
// second sentence, and Replace wrote it over the line: the first sentence, which both engines heard,
// was deleted from the transcript.
@MainActor
@Test("Replace writes the whole of the other engine's reading when it split the line in two (F572)")
func secondOpinionReplaceKeepsEverySentenceOfASplitLine() async throws {
    let (model, _) = try makeModel()
    let id = UUID()
    let stored = [seg("We ship on Friday. Then we review the numbrs.", 10.0, 18.0)]
    model.store.upsert(MeetingRecord(
        id: id, title: "M",
        recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed,
        transcriptText: TranscriptFormatter.timestamped(stored),
        segments: stored
    ))
    model.runTranscriptionEngineOverride = { _, _ in
        TranscriptionResult(
            id: "x", text: "We ship on Friday. Then we review the numbers.", languageCode: "en",
            audioDuration: 18, confidence: nil,
            segments: [seg("We ship on Friday.", 10.0, 13.0), seg("Then we review the numbers.", 13.0, 18.0)]
        )
    }

    await model.computeSecondOpinion(id: id)
    let diverging = try #require(model.secondOpinionSpans?.first { $0.kind == .diverge })
    model.applySecondOpinionSpan(diverging, to: id)

    let expected: [String] = ["We ship on Friday. Then we review the numbers."]
    #expect(model.store.meeting(id: id)?.segments.map(\.text) == expected)
}
