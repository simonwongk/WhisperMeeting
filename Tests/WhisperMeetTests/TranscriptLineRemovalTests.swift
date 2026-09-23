import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F422, F423, F424 — the app-level layer behind three controls: the transcription write that now
// removes a stuck decode's echoes, Delete Line in the Read view, Remove Repeated Lines for a
// transcript that already has echoes, and Remove Lines Not in <language>. Everything is driven
// through `AppModel` over a real temp `MeetingStore`, never by calling the WhisperCore cores
// directly, so these prove the results come back through the path the buttons use. The buttons
// themselves have no render harness in this target; `ContentView` source guards cover their wiring.

@MainActor
private func makeModel() -> (AppModel, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TranscriptLineRemovalTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(
        at: root.appendingPathComponent("Recordings", isDirectory: true),
        withIntermediateDirectories: true
    )
    let suite = "WhisperMeet.TranscriptLineRemovalTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    return (model, root)
}

private func line(_ text: String, _ start: Double?, _ end: Double?) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

/// The user's 27:51 exhibit in miniature: a lecture line, a Mandarin aside, sixteen `操！`, the
/// lecture again.
private func loopingLecture() -> [TranscriptSegment] {
    var segments = [
        line("So FDI is basically if the company has operations.", 10, 14),
        line("但你都不认识。", 15, 16),
    ]
    for copy in 0..<16 {
        let at = 20 + Double(copy) * 0.1
        segments.append(line("操！", at, at + 0.05))
    }
    segments.append(line("The question might ask you like what is going there.", 30, 35))
    return segments
}

/// A completed meeting whose stored text is the formatter's rendering of its segments, i.e. one the
/// user has not hand-edited.
@MainActor
private func storeCompletedMeeting(_ model: AppModel, segments: [TranscriptSegment], languageCode: String? = "en") -> UUID {
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id,
        title: "Lecture",
        status: .completed,
        transcriptText: TranscriptFormatter.timestamped(segments),
        languageCode: languageCode,
        segments: segments,
        transcriptNormalized: true
    ))
    return id
}

// MARK: - F422: the transcription write

@MainActor
@Test("A transcription result reaches the meeting with its stuck-decode echoes removed and counted (F422)")
func transcriptionWriteRemovesEchoes() {
    let (model, _) = makeModel()
    let id = UUID()
    model.store.upsert(MeetingRecord(id: id, title: "Lecture", status: .processing))
    let segments = loopingLecture()
    let result = TranscriptionResult(
        id: id.uuidString,
        text: segments.map(\.text).joined(separator: " "),
        languageCode: "en",
        audioDuration: 40,
        confidence: nil,
        segments: segments
    )

    model.apply(result: result, to: id)

    let stored = model.store.meeting(id: id)
    #expect(stored?.segments.map(\.text) == [
        "So FDI is basically if the company has operations.",
        "但你都不认识。",
        "操！",
        "The question might ask you like what is going there.",
    ])
    #expect(stored?.repeatsRemoved == 15)
    #expect(stored?.transcriptText.components(separatedBy: "操！").count == 2)
    // The stored text is the rendering of the stored lines, so nothing reads as a manual edit and
    // every Improve tool stays available.
    #expect(stored?.isTranscriptEdited == false)
}

@MainActor
@Test("A clean result stores no count, and re-transcribing clears an earlier one (F422)")
func cleanResultClearsTheCount() {
    let (model, _) = makeModel()
    let id = UUID()
    model.store.upsert(MeetingRecord(id: id, title: "Lecture", status: .processing, repeatsRemoved: 15))
    let segments = [line("Hello.", 0, 1), line("World.", 1, 2)]
    model.apply(result: TranscriptionResult(
        id: id.uuidString, text: "Hello. World.", languageCode: "en", audioDuration: 2,
        confidence: nil, segments: segments
    ), to: id)

    #expect(model.store.meeting(id: id)?.repeatsRemoved == nil)
    #expect(model.store.meeting(id: id)?.segments == segments)
}

@MainActor
@Test("An untimed result has its in-line loop removed from the text it stores (F422)")
func untimedResultIsCleanedToo() {
    let (model, _) = makeModel()
    let id = UUID()
    model.store.upsert(MeetingRecord(id: id, title: "Lecture", status: .processing))
    let text = "但你都不认识。" + String(repeating: "操！", count: 16) + "The question might ask you."
    model.apply(result: TranscriptionResult(
        id: id.uuidString, text: text, languageCode: "en", audioDuration: 40, confidence: nil,
        segments: [], alignmentWarning: "Timestamp alignment unavailable; complete text preserved."
    ), to: id)

    #expect(model.store.meeting(id: id)?.transcriptText == "但你都不认识。操！The question might ask you.")
    #expect(model.store.meeting(id: id)?.repeatsRemoved == 15)
}

// MARK: - F422: Remove Repeated Lines on an existing transcript

@MainActor
@Test("Remove Repeated Lines cleans a stored transcript, adds to the count, and undoes exactly (F422)")
func removeRepeatedLinesOnAStoredTranscript() throws {
    let (model, _) = makeModel()
    let segments = loopingLecture()
    let id = storeCompletedMeeting(model, segments: segments)
    model.store.update(id: id) { $0.repeatsRemoved = 2 }

    #expect(model.removableRepeatCount(for: id) == 15)
    let removal = try #require(model.removeRepeatedLines(from: id))

    let stored = try #require(model.store.meeting(id: id))
    #expect(stored.segments.count == 4)
    #expect(stored.repeatsRemoved == 17)
    #expect(stored.isTranscriptEdited == false)
    #expect(model.removableRepeatCount(for: id) == 0)

    #expect(model.undoTranscriptLineRemoval(removal))
    let restored = try #require(model.store.meeting(id: id))
    #expect(restored.segments == segments)
    #expect(restored.transcriptText == TranscriptFormatter.timestamped(segments))
    #expect(restored.repeatsRemoved == 2)
}

@MainActor
@Test("Nothing is removed from a hand-edited transcript (F422, F423)")
func handEditedTranscriptIsLeftAlone() {
    let (model, _) = makeModel()
    let segments = loopingLecture()
    let id = storeCompletedMeeting(model, segments: segments)
    model.store.update(id: id) { $0.transcriptText = "My own notes on the lecture." }

    #expect(model.lineRemovalBlockedReason(for: id) != nil)
    #expect(model.removeRepeatedLines(from: id) == nil)
    #expect(model.removeTranscriptLines(at: [1], from: id) == nil)
    #expect(model.store.meeting(id: id)?.segments == segments)
    #expect(model.store.meeting(id: id)?.transcriptText == "My own notes on the lecture.")
}

// MARK: - F423: Delete Line

@MainActor
@Test("Deleting a line removes exactly that line, rebuilds the text, and never touches the audio (F423)")
func deletingALineRemovesOnlyThatLine() throws {
    let (model, root) = makeModel()
    let segments = [
        line("So FDI is basically if the company has operations.", 10, 14),
        line("别笑。", 15, 16),
        line("That it controls in another country.", 17, 20),
    ]
    let id = storeCompletedMeeting(model, segments: segments)
    let audio = root.appendingPathComponent("Recordings/\(id.uuidString)/meeting.wav")
    try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
    let audioBytes = Data("RIFF-not-really-a-wav".utf8)
    try audioBytes.write(to: audio)
    model.store.update(id: id) { $0.recordingPath = "Recordings/\(id.uuidString)/meeting.wav" }

    #expect(model.lineRemovalBlockedReason(for: id) == nil)
    let removal = try #require(model.removeTranscriptLines(at: [1], from: id))

    let stored = try #require(model.store.meeting(id: id))
    #expect(stored.segments == [segments[0], segments[2]])
    #expect(stored.transcriptText == TranscriptFormatter.timestamped([segments[0], segments[2]]))
    #expect(stored.isTranscriptEdited == false)
    // Deleting a line is not a stuck decode's echo, so it is not counted as one.
    #expect(stored.repeatsRemoved == nil)
    #expect(try Data(contentsOf: audio) == audioBytes)

    #expect(model.undoTranscriptLineRemoval(removal))
    #expect(model.store.meeting(id: id)?.segments == segments)
}

@MainActor
@Test("Undo is refused once the transcript has changed again, rather than overwriting it (F423)")
func undoIsRefusedAfterALaterChange() throws {
    let (model, _) = makeModel()
    let segments = [line("A.", 0, 1), line("B.", 1, 2), line("C.", 2, 3)]
    let id = storeCompletedMeeting(model, segments: segments)
    let first = try #require(model.removeTranscriptLines(at: [0], from: id))
    _ = try #require(model.removeTranscriptLines(at: [0], from: id))

    // Undoing the FIRST removal now would resurrect "B." as well as "A." — the later change wins.
    #expect(!model.undoTranscriptLineRemoval(first))
    #expect(model.store.meeting(id: id)?.segments == [segments[2]])
}

@MainActor
@Test("Out-of-range indices remove nothing and change nothing (F423)")
func outOfRangeIndicesAreIgnored() {
    let (model, _) = makeModel()
    let segments = [line("A.", 0, 1)]
    let id = storeCompletedMeeting(model, segments: segments)
    #expect(model.removeTranscriptLines(at: [5], from: id) == nil)
    #expect(model.removeTranscriptLines(at: [], from: id) == nil)
    #expect(model.store.meeting(id: id)?.segments == segments)
}

// MARK: - F424: Remove Lines Not in <language>

@MainActor
@Test("The lines offered for removal are the other language's, and confirming removes exactly them (F424)")
func languageFilterPicksAndRemovesTheOtherLanguage() throws {
    let (model, _) = makeModel()
    let segments = [
        line("So FDI is basically if the company has operations.", 10, 14),
        line("别笑。", 15, 16),
        line("That it controls in another country.", 17, 20),
        line("真是很别扭。", 21, 22),
        line("2026", 23, 24),
    ]
    let id = storeCompletedMeeting(model, segments: segments, languageCode: "en")

    let offer = try #require(model.linesOutsideMeetingLanguage(for: id))
    #expect(offer.language == .english)
    #expect(offer.indices == [1, 3])

    _ = try #require(model.removeTranscriptLines(at: IndexSet(offer.indices), from: id))
    #expect(model.store.meeting(id: id)?.segments == [segments[0], segments[2], segments[4]])
    #expect(model.linesOutsideMeetingLanguage(for: id)?.indices == [])
}

// MARK: - F422: the new persisted field, both directions

@Test("An index written before repeatsRemoved existed still decodes, as nil (F422)")
func indexWithoutTheCountDecodes() throws {
    let json = """
    {"id":"\(UUID().uuidString)","title":"old","createdAt":700000000,"duration":0,
     "recordingPath":"","status":"completed","transcriptText":"","segments":[]}
    """
    let restored = try JSONDecoder().decode(MeetingRecord.self, from: Data(json.utf8))
    #expect(restored.repeatsRemoved == nil)
}

@Test("A key this build does not know is ignored, which is how the previous build reads repeatsRemoved (F422)")
func unknownKeysAreIgnoredOnDecode() throws {
    // The shipped build decodes with this same synthesized `init(from:)` over a hand-written
    // `CodingKeys` that lacks `repeatsRemoved`; keyed decoding ignores keys it does not list. This
    // proves the property with a key THIS build lacks, which is the same situation seen from the
    // other side, and pins the one thing that would break it: a strict decoder.
    let json = """
    {"id":"\(UUID().uuidString)","title":"new","createdAt":700000000,"duration":0,
     "recordingPath":"","status":"completed","transcriptText":"x","segments":[],
     "repeatsRemoved":15,"aFieldFromTheFuture":{"nested":[1,2,3]}}
    """
    let restored = try JSONDecoder().decode(MeetingRecord.self, from: Data(json.utf8))
    #expect(restored.title == "new")
    #expect(restored.repeatsRemoved == 15)
}

@Test("repeatsRemoved survives a save and reload (F422)")
func theCountRoundTrips() throws {
    let record = MeetingRecord(title: "t", status: .completed, repeatsRemoved: 15)
    let restored = try JSONDecoder().decode(MeetingRecord.self, from: JSONEncoder().encode(record))
    #expect(restored.repeatsRemoved == 15)
}
