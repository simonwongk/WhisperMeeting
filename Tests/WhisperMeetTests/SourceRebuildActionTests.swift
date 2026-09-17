import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F267 — the user-triggered half: an explicit, reviewed "rebuild from source audio".
//
// Shaped like F193's library recovery, including the structural guarantee that makes
// "user-reviewed" real rather than conventional: only an offer this model actually produced can
// be acted on, so a caller cannot rebuild something the user never saw.

@MainActor
private func makeModel(root: URL, suite: String) -> AppModel {
    AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: suite)!
    )
}

/// A meeting whose indexed audio is a short rebuild, with full-length raw tracks beside it.
@MainActor
private func makeTruncatedMeeting(in root: URL) throws -> (AppModel, UUID, URL) {
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let samples = [Float](repeating: 0.3, count: 96_000)          // 2s of tracks
    for name in ["system-audio.f32", "microphone-audio.f32"] {
        try samples.withUnsafeBytes { try Data($0).write(to: folder.appendingPathComponent(name)) }
    }
    try WAVWriter.wavData(from: [Float](repeating: 0.1, count: 4_800), sampleRate: 48_000)
        .write(to: folder.appendingPathComponent("meeting-recovered.wav"))   // 0.1s indexed

    let suite = "WhisperMeet.SourceRebuildAction.\(UUID().uuidString)"
    let model = makeModel(root: root, suite: suite)
    model.store.upsert(MeetingRecord(
        id: id,
        title: "Pricing sync",
        duration: 0.1,
        recordingPath: "Recordings/\(id.uuidString)/meeting-recovered.wav",
        status: .completed,
        transcriptText: "0:00 We agreed on the tiering.",
        segments: [
            TranscriptSegment(speaker: nil, start: 0, end: 0.1, text: "We agreed on the tiering.")
        ],
        markers: [RecordingMarker(offset: 0.05, label: "pricing")],
        notes: "Ask about the annual discount",
        tags: ["finance"],
        recoveryWarning: "The rebuilt audio stops at 0:00 because a source track could not be read past that point."
    ))
    return (model, id, folder)
}

@Test("A truncated meeting can be rebuilt again, and gains the longer audio")
@MainActor
func rebuildProducesTheLongerRecording() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RebuildAction-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, id, folder) = try makeTruncatedMeeting(in: root)

    model.requestSourceRebuild(id: id)
    let offer = try #require(model.pendingSourceRebuild)
    #expect(offer.meetingTitle == "Pricing sync")
    #expect(offer.offer.expectedDurationSeconds == 2.0)

    model.performSourceRebuild(confirmed: true)

    let meeting = try #require(model.store.meeting(id: id))
    #expect(abs(meeting.duration - 2.0) < 0.01)
    // The rebuild read cleanly this time, so the truncation notice is gone rather than stale.
    #expect(meeting.recoveryWarning == nil)
    #expect(model.pendingSourceRebuild == nil)
    // And the audio it replaced is still on disk.
    #expect(FileManager.default.fileExists(
        atPath: folder.appendingPathComponent("meeting-recovered-superseded-1.wav").path
    ))
}

@Test("A rebuild changes the audio's facts and nothing the user wrote")
@MainActor
func rebuildPreservesEveryUserField() throws {
    // F148 #1, asserted field by field rather than by a spot check. A rebuild that blanks a
    // user's text is worse than the imperfect audio it replaces, and it is the whole reason this
    // action is safe enough to offer.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RebuildPreserve-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, id, _) = try makeTruncatedMeeting(in: root)
    let before = try #require(model.store.meeting(id: id))

    model.requestSourceRebuild(id: id)
    model.performSourceRebuild(confirmed: true)

    let after = try #require(model.store.meeting(id: id))
    #expect(after.title == before.title)
    #expect(after.transcriptText == before.transcriptText)
    #expect(after.segments == before.segments)
    #expect(after.notes == before.notes)
    #expect(after.tags == before.tags)
    #expect(after.summary == before.summary)
    #expect(after.markers == before.markers)
    #expect(after.recordingPath == before.recordingPath)
}

@Test("A longer rebuild says the transcript no longer describes the audio")
@MainActor
func longerRebuildMarksTheTranscriptStale() throws {
    // F281's rule, applied to a new case: the transcript covers only the old prefix and its
    // timestamps point into a file that has been replaced. Blanking it is forbidden and would be
    // the greater harm, so it stays — and nothing contradicting it would make the document read
    // as current, which is a false claim by omission.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RebuildStale-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, id, _) = try makeTruncatedMeeting(in: root)

    model.requestSourceRebuild(id: id)
    model.performSourceRebuild(confirmed: true)

    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.staleTranscriptWarning?.contains("rebuilt") == true)
    // And it reaches the notes.md mirror through the caveats list F281 built.
    model.store.flushPendingNotesSidecars()
    let notes = try String(
        contentsOf: root.appendingPathComponent("Recordings/\(id.uuidString)/notes.md"),
        encoding: .utf8
    )
    #expect(notes.contains("## About this recording"))
    #expect(notes.contains("rebuilt"))
}

@Test("An untranscribed meeting gains no stale-transcript notice")
@MainActor
func untranscribedRebuildSaysNothingAboutTheTranscript() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RebuildNoText-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let samples = [Float](repeating: 0.3, count: 96_000)
    try samples.withUnsafeBytes { try Data($0).write(to: folder.appendingPathComponent("system-audio.f32")) }
    try WAVWriter.wavData(from: [Float](repeating: 0.1, count: 4_800), sampleRate: 48_000)
        .write(to: folder.appendingPathComponent("meeting-recovered.wav"))

    let model = makeModel(root: root, suite: "WhisperMeet.RebuildNoText.\(UUID().uuidString)")
    model.store.upsert(MeetingRecord(
        id: id,
        title: "Never transcribed",
        duration: 0.1,
        recordingPath: "Recordings/\(id.uuidString)/meeting-recovered.wav",
        status: .recorded
    ))

    model.requestSourceRebuild(id: id)
    model.performSourceRebuild(confirmed: true)

    #expect(model.store.meeting(id: id)?.staleTranscriptWarning == nil)
}

@Test("Without confirmation nothing happens at all")
@MainActor
func unconfirmedRebuildIsANoOp() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RebuildUnconfirmed-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, id, folder) = try makeTruncatedMeeting(in: root)

    model.requestSourceRebuild(id: id)
    model.performSourceRebuild(confirmed: false)

    #expect(model.store.meeting(id: id)?.duration == 0.1)
    #expect(model.pendingSourceRebuild != nil, "the offer stays up; the user has not answered yet")
    #expect(!FileManager.default.fileExists(
        atPath: folder.appendingPathComponent("meeting-recovered-superseded-1.wav").path
    ))
}

@Test("A rebuild the model never offered is refused")
@MainActor
func unofferedRebuildIsRefused() throws {
    // The same structural guarantee F193 established: "user-reviewed" enforced by the code, not
    // by convention. Without this a caller could rebuild a meeting the user never saw a prompt for.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RebuildUnoffered-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, id, _) = try makeTruncatedMeeting(in: root)

    model.performSourceRebuild(confirmed: true)   // never requested

    #expect(model.store.meeting(id: id)?.duration == 0.1)
}

@Test("A meeting with a finished capture is told why it cannot be rebuilt")
@MainActor
func finishedCaptureExplainsTheRefusal() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RebuildFinished-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let samples = [Float](repeating: 0.3, count: 96_000)
    try samples.withUnsafeBytes { try Data($0).write(to: folder.appendingPathComponent("system-audio.f32")) }
    try WAVWriter.wavData(from: samples, sampleRate: 48_000)
        .write(to: folder.appendingPathComponent("meeting.wav"))

    let model = makeModel(root: root, suite: "WhisperMeet.RebuildFinished.\(UUID().uuidString)")
    model.store.upsert(MeetingRecord(
        id: id,
        title: "Finished normally",
        duration: 2.0,
        recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed
    ))

    model.requestSourceRebuild(id: id)

    // Refused, and explained rather than silently absent — the user asked for something.
    #expect(model.pendingSourceRebuild == nil)
    #expect(model.alertMessage?.isEmpty == false)
    #expect(model.canRebuildFromSourceTracks(id: id) == false)
}

@Test("The confirmation states what changes, what is kept, and what it costs")
@MainActor
func confirmationDisclosesTheTrade() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RebuildCopy-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, id, _) = try makeTruncatedMeeting(in: root)

    model.requestSourceRebuild(id: id)
    let request = try #require(model.pendingSourceRebuild)
    let message = AppModel.rebuildConfirmationMessage(request)

    #expect(message.contains("Pricing sync"))
    #expect(message.contains("0:00"))   // what it has now
    #expect(message.contains("0:02"))   // what the tracks hold
    // The cost is disclosed rather than solved.
    #expect(message.contains("grow"))
    // And the F148 #1 guarantee is stated to the user, not just honoured in code.
    #expect(message.contains("transcript"))
}

@Test("A meeting with no previous audio is not told its folder will grow")
@MainActor
func missingRecordingConfirmationOmitsTheCost() throws {
    // Nothing to keep means no extra copy, so claiming a cost would be a small false statement.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RebuildNoCost-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let samples = [Float](repeating: 0.3, count: 96_000)
    try samples.withUnsafeBytes { try Data($0).write(to: folder.appendingPathComponent("system-audio.f32")) }

    let model = makeModel(root: root, suite: "WhisperMeet.RebuildNoCost.\(UUID().uuidString)")
    model.store.upsert(MeetingRecord(
        id: id,
        title: "Lost audio",
        recordingPath: "Recordings/\(id.uuidString)/meeting-recovered.wav",
        status: .recorded
    ))

    model.requestSourceRebuild(id: id)
    let request = try #require(model.pendingSourceRebuild)
    #expect(!AppModel.rebuildConfirmationMessage(request).contains("grow"))
}

// MARK: - F306: the offer has to be reachable, not merely correct

@Test("The view layer still reaches the source rebuild (F306)")
func theRebuildOfferIsReachableFromTheView() throws {
    // F273 consolidated three hand-written banners into one `ForEach` list — a good change — and
    // deleted the Rebuild Audio button that lived inside one of them. `requestSourceRebuild` then
    // had no production caller: the confirmation dialog reads `pendingSourceRebuild`, which only
    // that method sets, so F267's entire rebuild became unreachable and `staleTranscriptWarning`
    // could never be set. Every test in this file kept passing, because they all drive the model
    // directly.
    //
    // Asserted against `ContentView`'s source, which is crude and is the honest option: the
    // `WhisperMeet` target has no UI harness (F174's standing reason), so there is no way to render
    // the view and look. `InstallReclaimTests` set the precedent of asserting against source when
    // the behaviour itself is out of reach. It would have caught this exact regression, which is
    // the bar that matters.
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // WhisperMeetTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repository root
        .appendingPathComponent("Sources/WhisperMeet/ContentView.swift")
    let source = try String(contentsOf: url, encoding: .utf8)
        // Comments stripped, so a mention of the name in prose — including the explanation of this
        // very regression — cannot satisfy the assertion. F285's false positive was exactly that.
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : String($0) }
        .joined(separator: "\n")

    #expect(
        source.contains("requestSourceRebuild"),
        "no view calls requestSourceRebuild, so the rebuild cannot be started — F267's mechanism is unreachable"
    )
    #expect(
        source.contains("canRebuildFromSourceTracks"),
        "the offer must be gated on whether raw tracks exist, or it is shown when it cannot work"
    )
    #expect(
        source.contains("performSourceRebuild"),
        "the confirmation must be able to run the rebuild"
    )
}
