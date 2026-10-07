import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F667 — after a lost save at Stop (F642 routes `upsert` through the conflict offer), the new meeting
// was only in the offer: unlisted until the person answered, and dropped by "Use the Other Copy",
// its audio left as an orphan until a launch adopted it. The banner never said which meetings either
// answer decides, so nothing warned that one of them was the recording just made.
//
// A meeting only this window has is not a question — the other copy has no version of it to prefer —
// so it is put back onto the reloaded library and saved at once. The banner names what the answer
// does decide, and says the new meeting is kept either way. These drive the real `AppModel` Stop over
// two `BackupJSONStore` writers on one temp root.

@MainActor
private func makeModel() throws -> (AppModel, URL, () -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F667-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "F667.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let recorder = AudioCaptureEngine(
        stoppingCapture: {}, finishingTracks: {}, preservingPartialTracks: {},
        startingCapture: { _, _, _ in }, restartingCapture: { _ in }, directory: root
    )
    // A long debounce, so a notes edit is still pending — unsaved — when Stop saves.
    let model = AppModel(
        store: MeetingStore(rootDirectory: root, transcriptWriteDebounce: 60), recorder: recorder,
        defaults: defaults, whisperExecutable: { nil }, qwenInstalled: { false }
    )
    return (model, root, {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    })
}

/// Another copy of the app reading what is on disk and committing `change` of it.
@MainActor
private func otherCopyCommits(in root: URL, _ change: ([MeetingRecord]) -> [MeetingRecord]) throws {
    let rival = BackupJSONStore<[MeetingRecord]>(
        primaryURL: root.appendingPathComponent("meetings.json"),
        backupURL: root.appendingPathComponent("meetings.backup.json"),
        writer: "ffff9999",
        recordCount: { $0.count }
    )
    let seen = try rival.load()
    _ = try rival.save(change(seen?.value ?? []), expecting: seen?.token)
}

@MainActor
private func onDisk(_ root: URL, _ id: UUID) -> MeetingRecord? {
    MeetingStore(rootDirectory: root).meeting(id: id)
}

@MainActor
private func recordTwoSeconds(_ model: AppModel, title: String) async throws -> UUID {
    model.recordingTitle = title
    await model.startRecording()
    let id = try #require(model.activeMeetingID)
    try model.recorder.beginTestTrackSession(in: model.store.recordingDirectoryURL(for: id))
    try model.recorder.writeTestFrames(system: 48_000 * 2, microphone: 48_000 * 2, systemStart: 0, microphoneStart: 0)
    return id
}

private let theirTitle = "Standup, renamed by the other copy"

@MainActor
@Test("A Stop that loses to another copy lists the recording at once; the banner names it and the edit it decides; Use the Other Copy keeps it (F667)")
func lostStopKeepsTheRecordingAndNamesWhatTheBannerDecides() async throws {
    let (model, root, cleanup) = try makeModel()
    defer { cleanup() }
    let store = model.store
    let standup = UUID()
    store.upsert(MeetingRecord(id: standup, title: "Standup", status: .completed))
    let id = try await recordTwoSeconds(model, title: "Board call")
    // During the call: another copy renames the standup, and this window types a note on it.
    try otherCopyCommits(in: root) { records in
        records.map { var record = $0; if record.id == standup { record.title = theirTitle }; return record }
    }
    store.editNotes(id: standup, text: "a note typed during the call")

    let saved = try #require(await model.stopRecording(title: model.recordingTitle))

    #expect(saved == id)
    #expect(store.meeting(id: id)?.title == "Board call", "the recording was hidden until the banner was answered")
    #expect(onDisk(root, id)?.title == "Board call", "the recording was not saved onto the reloaded library")
    #expect(store.meeting(id: standup)?.title == theirTitle, "the library was not re-read")
    let offer = try #require(store.conflictOffer, "the unsaved note is still the person's to decide")
    #expect(offer.delta.contains { $0.id == standup && $0.notes == "a note typed during the call" })
    #expect(!offer.delta.contains { $0.id == id }, "the recording was offered as if the other copy had a version of it")
    // The banner names what each answer decides, and the recording it does not.
    #expect(offer.message.contains("Standup"), "the banner does not name the meeting it decides: \(offer.message)")
    #expect(offer.message.contains("Board call"), "the banner does not name the new recording: \(offer.message)")
    #expect(offer.message.contains("Use the Other Copy"), "the banner does not say what its answers do: \(offer.message)")

    store.discardConflictedEdit()

    #expect(store.meeting(id: id)?.title == "Board call", "Use the Other Copy dropped the recording")
    #expect(onDisk(root, id)?.title == "Board call")
    #expect(onDisk(root, standup)?.title == theirTitle)
    #expect(onDisk(root, standup)?.notes == nil)
}

@MainActor
@Test("A Stop that loses with nothing else unsaved saves the recording without raising the banner (F667)")
func lostStopWithNothingToDecideRaisesNoBanner() async throws {
    let (model, root, cleanup) = try makeModel()
    defer { cleanup() }
    let store = model.store
    // A library that already has an index: a store with no token saves unchecked (`expecting: nil`).
    store.upsert(MeetingRecord(id: UUID(), title: "Standup", status: .completed))
    let theirs = MeetingRecord(id: UUID(), title: "The other copy's meeting", status: .recorded)
    let id = try await recordTwoSeconds(model, title: "Board call")
    try otherCopyCommits(in: root) { $0 + [theirs] }

    _ = try #require(await model.stopRecording(title: model.recordingTitle))

    #expect(store.conflictOffer == nil, "a meeting only this window has is not a question to ask")
    #expect(store.writeConflict == nil)
    #expect(onDisk(root, id)?.title == "Board call")
    #expect(onDisk(root, theirs.id) != nil, "the other copy's meeting was overwritten")
    // And the next save is compared against what is on disk now.
    store.update(id: id) { $0.title = "Board call, renamed" }
    #expect(onDisk(root, id)?.title == "Board call, renamed")
}

/// What Keep and Use the Other Copy each do is said in the banner, with the meetings it applies to,
/// for an ordinary edit too — not only around a recording.
@MainActor
@Test("The banner names the meetings Keep would save over the other copy's (F667)")
func bannerNamesTheEditedMeetings() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F667-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = UUID(), b = UUID()
    let seed = MeetingStore(rootDirectory: root)
    seed.upsert(MeetingRecord(id: a, title: "Planning", status: .completed))
    seed.upsert(MeetingRecord(id: b, title: "Retro", status: .completed))
    let store = MeetingStore(rootDirectory: root)
    try otherCopyCommits(in: root) { $0.map { var r = $0; r.notes = "theirs"; return r } }

    store.addTag("q3", to: [a, b])

    let offer = try #require(store.conflictOffer)
    #expect(offer.message.contains("Planning") && offer.message.contains("Retro"), "\(offer.message)")
    #expect(offer.message.contains("Keep My Edit"), "\(offer.message)")
}

/// If the save that puts a new meeting back loses as well — the other copy saved again between this
/// window's reload and that save — the recovery does not try a third time: the meeting is held by the
/// banner, named, and either answer saves it. (`beforeIndexSaveForTesting` puts the other copy's
/// commit inside that one call; nothing else can.)
@MainActor
@Test("A new meeting whose second save loses too is held by the banner, and either answer saves it (F667)", arguments: [true, false])
func newMeetingThatLosesTwiceIsSavedByEitherAnswer(keep: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F667-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let standup = UUID()
    MeetingStore(rootDirectory: root).upsert(MeetingRecord(id: standup, title: "Standup", status: .completed))
    let store = MeetingStore(rootDirectory: root)
    try otherCopyCommits(in: root) { $0.map { var r = $0; r.title = theirTitle; return r } }
    let theirs = MeetingRecord(id: UUID(), title: "The other copy's meeting", status: .recorded)
    var saves = 0
    store.beforeIndexSaveForTesting = {
        saves += 1
        // The second save is the one that puts the new meeting back after the first reload.
        if saves == 2 { try? otherCopyCommits(in: root) { $0 + [theirs] } }
    }
    let recorded = MeetingRecord(id: UUID(), title: "Board call", status: .recorded)

    store.upsert(recorded, as: .result)

    try #require(saves == 2, "fixture: the new meeting's own save after the reload was meant to run")
    store.beforeIndexSaveForTesting = nil
    #expect(store.writeConflict == nil, "the second race was left raw")
    let offer = try #require(store.conflictOffer, "the new meeting was dropped by the second race")
    #expect(offer.unsavedNew.map(\.id) == [recorded.id])
    #expect(offer.delta.isEmpty, "a meeting only this window has was offered as an edit")
    #expect(offer.message.contains("“Board call” is new in this window"), "\(offer.message)")
    #expect(store.meeting(id: theirs.id) != nil, "the library was not re-read after the second race")

    if keep { store.keepConflictedEdit() } else { store.discardConflictedEdit() }

    #expect(store.conflictOffer == nil)
    #expect(store.writeConflict == nil)
    #expect(store.meeting(id: recorded.id) != nil, keep ? "Keep My Edit did not save the new meeting" : "Use the Other Copy dropped the new meeting")
    #expect(onDisk(root, recorded.id) != nil)
    #expect(onDisk(root, theirs.id) != nil, "the other copy's meeting was overwritten")
    #expect(onDisk(root, standup)?.title == theirTitle)
}

/// When the re-read itself leaves the library read-only — here the wipe shape: the other copy saved an
/// empty list beside a finished recording, which loads as suspect-empty — nothing may be saved, so the
/// new meeting cannot be put back. The banner must not promise that either answer saves it; it says the
/// recording stays on this Mac until the library is recovered, and nothing is written.
@MainActor
@Test("A new meeting whose race leaves the library read-only is not promised a save it cannot get (F667)")
func newMeetingOnALibraryLeftReadOnlyIsDescribedHonestly() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F667-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let imported = UUID()
    let folder = root.appendingPathComponent("Recordings/\(imported.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("finished import".utf8).write(to: folder.appendingPathComponent("recording.mp3"))
    MeetingStore(rootDirectory: root).upsert(MeetingRecord(
        id: imported, title: "Imported", recordingPath: "Recordings/\(imported.uuidString)/recording.mp3",
        status: .completed
    ))
    let store = MeetingStore(rootDirectory: root)
    try otherCopyCommits(in: root) { _ in [] }

    store.upsert(MeetingRecord(id: UUID(), title: "Board call", status: .recorded), as: .result)

    try #require(store.isDegraded, "fixture: the empty list beside a finished recording reloads read-only")
    let offer = try #require(store.conflictOffer, "the new meeting was dropped without a word")
    #expect(offer.unsavedNew.map(\.title) == ["Board call"])
    #expect(!offer.message.contains("either answer saves"), "the banner promised a save the library refuses: \(offer.message)")
    #expect(offer.message.contains("cannot be saved while the library cannot be written"), "\(offer.message)")
    #expect(MeetingStore(rootDirectory: root).meetings.isEmpty, "something was written to a read-only library")
}
