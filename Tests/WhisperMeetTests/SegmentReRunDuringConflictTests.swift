import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F863 — a segment re-run finishing while the conflict banner is up was dropped without a word.
//
// "Re-transcribe this segment" writes its line through `store.update(id:)` as the person's own change,
// and while a lost race's banner is up those wait for its answer (F619): the store refuses them without
// a message, because the banner explains a refused keystroke. The engine had run for seconds or minutes,
// the closure never ran, none of its flags was set, and nothing was said. It is now said — when the
// banner appears while the engine runs — and the re-run is refused before it starts while the banner is
// already up.

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

private let lines = [seg("first", 0, 1), seg("second wrong", 1, 2), seg("third", 2, 3)]

private let rerun = TranscriptionResult(id: "x", text: "second right", languageCode: "en", audioDuration: 1,
                                        confidence: nil, segments: [seg("second right", 0, 1)])

/// A completed meeting over three seconds of silent 16 kHz mono audio, and a second meeting the banner
/// will be about.
@MainActor
private func makeLibrary() throws -> (AppModel, meeting: UUID, other: UUID, root: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F863-\(UUID().uuidString)")
    let id = UUID(), other = UUID()
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
    model.store.upsert(MeetingRecord(id: other, title: "Standup", status: .completed))
    return (model, id, other, root)
}

/// Another copy renames `other`, and this window's rename of it loses: the banner is up.
@MainActor
private func raiseTheBanner(on store: MeetingStore, root: URL, about other: UUID) throws {
    let rival = BackupJSONStore<[MeetingRecord]>(
        primaryURL: root.appendingPathComponent("meetings.json"),
        backupURL: root.appendingPathComponent("meetings.backup.json"),
        writer: "ffff9999",
        recordCount: { $0.count }
    )
    let seen = try rival.load()
    let renamed = (seen?.value ?? []).map { record -> MeetingRecord in
        var record = record
        if record.id == other { record.title = "Standup, renamed by the other copy" }
        return record
    }
    _ = try rival.save(renamed, expecting: seen?.token)
    store.update(id: other) { $0.title = "Standup, renamed here" }
}

@MainActor
@Test("A segment re-run that finishes while the conflict banner is up says its line was not put in (F863)")
func segmentReRunFinishingUnderTheBannerSaysSo() async throws {
    let (model, id, other, root) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    model.runTranscriptionEngineOverride = { _, _ in
        // While the engine works on the line, another copy changes the library and this window's next
        // change loses: the banner appears.
        try await MainActor.run { try raiseTheBanner(on: model.store, root: root, about: other) }
        return rerun
    }

    await model.reTranscribeSegment(id: id, index: 1)

    try #require(model.store.conflictOffer != nil, "fixture: the banner came up while the engine ran")
    let texts: [String]? = model.store.meeting(id: id)?.segments.map(\.text)
    #expect(texts == ["first", "second wrong", "third"], "the line was put in while the banner was up")
    let said = try #require(model.alertMessage, "the re-run's line was dropped without a word")
    #expect(said.contains("Keep My Edit") && said.contains("Use the Other Copy"), "\(said)")
}

@MainActor
@Test("A segment re-run is refused before the engine starts while the conflict banner is up (F863)")
func segmentReRunIsRefusedWhileTheBannerIsUp() throws {
    let (model, id, other, root) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    // Never the real engine, whatever this test finds: a stub that only answers.
    model.runTranscriptionEngineOverride = { _, _ in rerun }
    try raiseTheBanner(on: model.store, root: root, about: other)
    try #require(model.store.conflictOffer != nil, "fixture: the banner is up")

    model.requestSegmentReTranscription(id: id, index: 1)

    #expect(!model.isRunningAuxiliaryEngine, "the engine was started for a line that cannot be put in")
    let said = try #require(model.alertMessage, "nothing said why the re-run did not start")
    #expect(said.contains("Keep My Edit") && said.contains("Use the Other Copy"), "\(said)")
}
