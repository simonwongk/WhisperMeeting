import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F573 — "Re-transcribe this segment" remembered the line by its INDEX before the engine ran, and
// put the result in at that index when the engine returned. Delete Line, Remove Repeated Lines,
// Remove Lines in Another Language and their Undo are not blocked while an engine runs, so a line
// removed meanwhile shifted every line after it: the re-run's text then overwrote the NEXT line,
// silently, and the line it was run on stayed wrong. The line is now found again when the result is
// written, by its start and its text — as Second Opinion's Replace finds its line — and if it is
// gone, nothing is written.

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

private let lines = [seg("first", 0, 1), seg("second wrong", 1, 2), seg("third", 2, 3)]

/// A completed meeting over three seconds of silent 16 kHz mono audio.
@MainActor
private func makeMeeting() throws -> (AppModel, UUID, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F573-\(UUID().uuidString)")
    let id = UUID()
    let dir = root.appendingPathComponent("Recordings/\(id.uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var wav = WAVWriter.header(sampleRate: 16_000, dataByteCount: 96_000)
    wav.append(Data(count: 96_000))
    try wav.write(to: dir.appendingPathComponent("meeting.wav"))
    let defaults = try #require(UserDefaults(suiteName: testSuiteName()))
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    model.store.upsert(MeetingRecord(
        id: id, title: "M", recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed, transcriptText: TranscriptFormatter.timestamped(lines), segments: lines
    ))
    return (model, id, root)
}

private let rerun = TranscriptionResult(id: "x", text: "second right", languageCode: "en", audioDuration: 1,
                                        confidence: nil, segments: [seg("second right", 0, 1)])

@MainActor
@Test("A line deleted above the re-run line while the engine ran does not make the re-run overwrite its neighbour (F573)")
func segmentReRunReplacesTheLineItWasRunOnAfterAnEarlierLineIsRemoved() async throws {
    let (model, id, root) = try makeMeeting()
    defer { try? FileManager.default.removeItem(at: root) }
    model.runTranscriptionEngineOverride = { _, _ in
        // The user deletes the first line while the engine works on the second.
        let removed = await MainActor.run { model.removeTranscriptLines(at: IndexSet(integer: 0), from: id) }
        #expect(removed != nil, "the removal itself went through")
        return rerun
    }

    await model.reTranscribeSegment(id: id, index: 1)

    let texts: [String]? = model.store.meeting(id: id)?.segments.map(\.text)
    #expect(texts == ["second right", "third"], "the line it was run on is replaced, and 'third' is kept")
    #expect(model.alertMessage == nil)
}

@MainActor
@Test("A re-run whose line was deleted while the engine ran writes nothing, and says so (F573)")
func segmentReRunWritesNothingWhenItsLineWasRemoved() async throws {
    let (model, id, root) = try makeMeeting()
    defer { try? FileManager.default.removeItem(at: root) }
    model.runTranscriptionEngineOverride = { _, _ in
        let removed = await MainActor.run { model.removeTranscriptLines(at: IndexSet(integer: 1), from: id) }
        #expect(removed != nil, "the removal itself went through")
        return rerun
    }

    await model.reTranscribeSegment(id: id, index: 1)

    let texts: [String]? = model.store.meeting(id: id)?.segments.map(\.text)
    #expect(texts == ["first", "third"], "the deletion stands, and 'third' is not overwritten")
    #expect(model.alertMessage == AppModel.segmentReRunDiscardedLineGone)
}

@MainActor
@Test("With nothing removed, a re-run still replaces its line in place (F573 control)")
func segmentReRunStillReplacesInPlace() async throws {
    let (model, id, root) = try makeMeeting()
    defer { try? FileManager.default.removeItem(at: root) }
    model.runTranscriptionEngineOverride = { _, _ in rerun }

    await model.reTranscribeSegment(id: id, index: 1)

    let texts: [String]? = model.store.meeting(id: id)?.segments.map(\.text)
    #expect(texts == ["first", "second right", "third"])
    #expect(model.alertMessage == nil)
}
