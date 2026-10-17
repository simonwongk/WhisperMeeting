import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F609 — `FileManager.removeItem` on a folder is not atomic. A recording folder holding one file
// that cannot be removed lost everything else first, the delete then put the meeting back as "kept to
// avoid an inconsistent library", and the kept meeting pointed at audio that was gone. So a delete now
// takes the folder out of `Recordings/<id>` in one rename first: a rename that fails has changed
// nothing and keeps the meeting whole, and once it has succeeded the deletion stands, and whatever
// the removal cannot take is left in a hidden folder that the next launch sweeps.
//
// F579 — a batch delete that both kept a folder and removed an entry only said one of the two, and the
// shred pass that follows every delete replaced whichever it was.

@MainActor
private func makeLibrary(_ label: String) throws -> (MeetingStore, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F609-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (MeetingStore(rootDirectory: root), root)
}

/// A meeting with its own folder: `meeting.wav` and a `sub/` folder holding one more file.
@MainActor
private func addMeeting(_ store: MeetingStore, root: URL, title: String) throws -> (UUID, URL) {
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: folder.appendingPathComponent("meeting.wav"))
    try Data("track".utf8).write(to: folder.appendingPathComponent("sub/locked.f32"))
    store.upsert(MeetingRecord(
        id: id, title: title, recordingPath: "Recordings/\(id.uuidString)/meeting.wav", status: .completed
    ))
    return (id, folder)
}

/// Every hidden folder a delete left in `Recordings`.
private func setAsideFolders(in root: URL) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("Recordings").path
    )) ?? []
    return names.filter { $0.hasPrefix(".") }.sorted()
}

/// The invariant the ticket is about, asked of both the store in memory and a fresh read of the disk:
/// a listed meeting has its audio.
@MainActor
private func expectNoListedMeetingWithoutAudio(_ store: MeetingStore, root: URL, _ id: UUID,
                                               sourceLocation: SourceLocation = #_sourceLocation) {
    for (label, view) in [("in memory", store), ("after a relaunch", MeetingStore(rootDirectory: root))] {
        if let meeting = view.meeting(id: id) {
            #expect(FileManager.default.fileExists(atPath: view.recordingURL(for: meeting).path),
                    "\(label): the meeting is listed and its audio is gone", sourceLocation: sourceLocation)
        }
    }
}

// The reviewer's probe, as a test, on the real file system: a folder inside the recording folder that
// its own files cannot be removed from. Before F609 the removal took `meeting.wav`, failed on `sub/`,
// and the delete listed the meeting again with no audio.
@MainActor
@Test("A recording folder that can be only partly removed never leaves a listed meeting without its audio (F609)")
func partlyRemovableFolderNeverListsAMeetingWithoutAudio() throws {
    let (store, root) = try makeLibrary("probe")
    let (id, folder) = try addMeeting(store, root: root, title: "Board review")
    let sub = folder.appendingPathComponent("sub")
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sub.path)
    defer {
        // Whatever the delete did with it, open every folder again so the fixture can be removed.
        let recordings = root.appendingPathComponent("Recordings")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: recordings.path)) ?? [] {
            let inner = recordings.appendingPathComponent(name).appendingPathComponent("sub")
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inner.path)
        }
        try? FileManager.default.removeItem(at: root)
    }

    store.delete(ids: [id])

    expectNoListedMeetingWithoutAudio(store, root: root, id)
}

// The same shape through the seam, so it does not depend on what the file system refuses: the removal
// takes one file and then throws.
@MainActor
@Test("A removal that takes one file and then fails never leaves a listed meeting without its audio (F609)")
func removalThatFailsPartWayNeverListsAMeetingWithoutAudio() throws {
    let (store, root) = try makeLibrary("seam")
    defer { try? FileManager.default.removeItem(at: root) }
    let (id, _) = try addMeeting(store, root: root, title: "Board review")
    store.removeRecordingDirectory = { folder in
        try FileManager.default.removeItem(at: folder.appendingPathComponent("meeting.wav"))
        throw CocoaError(.fileWriteNoPermission)
    }

    store.delete(ids: [id])

    expectNoListedMeetingWithoutAudio(store, root: root, id)
}

// What the rename buys, stated positively: the deletion stands, `Recordings/<id>` is gone at once, the
// remnant is said, and the next launch removes it.
@MainActor
@Test("A deletion whose set-aside folder cannot be removed stands, says so, and the next launch removes the remnant (F609)")
func remnantIsSaidAndSweptAtTheNextLaunch() throws {
    let (store, root) = try makeLibrary("remnant")
    defer { try? FileManager.default.removeItem(at: root) }
    let (id, folder) = try addMeeting(store, root: root, title: "Board review")
    store.removeRecordingDirectory = { _ in throw CocoaError(.fileWriteNoPermission) }

    #expect(store.delete(ids: [id]) == [id])

    #expect(store.meeting(id: id) == nil)
    #expect(MeetingStore(rootDirectory: root).meeting(id: id) == nil, "the deletion did not reach the index")
    #expect(!FileManager.default.fileExists(atPath: folder.path), "the meeting's own folder is still in Recordings")
    let remnants = setAsideFolders(in: root)
    #expect(remnants.count == 1 && remnants.first?.contains(id.uuidString) == true, "\(remnants)")
    let message = try #require(store.storageErrorMessage, "a remnant on disk was not said")
    #expect(message.contains("Board review"), "\(message)")
    #expect(try store.orphanedRecordings().isEmpty, "the remnant was listed as a recording to recover")

    let relaunched = MeetingStore(rootDirectory: root)
    #expect(relaunched.sweepSetAsideRecordings() == nil)
    #expect(setAsideFolders(in: root).isEmpty, "the next launch left the remnant on disk")
}

// The other half: a folder that cannot even be moved has not been touched, so keeping the meeting is
// a true rollback.
@MainActor
@Test("A recording folder that cannot be set aside keeps the meeting with every file in place (F609)")
func folderThatCannotBeSetAsideIsKeptWhole() throws {
    let (store, root) = try makeLibrary("unmovable")
    defer { try? FileManager.default.removeItem(at: root) }
    let (id, folder) = try addMeeting(store, root: root, title: "Board review")
    var removals = 0
    store.setRecordingDirectoryAside = { _ in throw CocoaError(.fileWriteNoPermission) }
    store.removeRecordingDirectory = { _ in removals += 1 }

    #expect(store.delete(ids: [id]).isEmpty)

    #expect(store.meeting(id: id) != nil)
    #expect(MeetingStore(rootDirectory: root).meeting(id: id) != nil)
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("meeting.wav").path))
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("sub/locked.f32").path))
    #expect(removals == 0)
    #expect(store.storageErrorMessage?.contains("Board review") == true)
}

// Deferred, never destructive: a remnant whose meeting is listed again — a hand restore of an older
// index — is not the sweep's to remove, and neither is a hidden folder whose name it did not write.
@MainActor
@Test("The sweep leaves a remnant whose meeting is listed again, and a hidden folder it did not name (F609)")
func sweepLeavesWhatIsNotADeletedMeetings() throws {
    let (store, root) = try makeLibrary("sweep")
    defer { try? FileManager.default.removeItem(at: root) }
    let live = UUID()
    store.upsert(MeetingRecord(id: live, title: "Back again", recordingPath: "Recordings/\(live.uuidString)/meeting.wav", status: .completed))
    let recordings = root.appendingPathComponent("Recordings")
    let liveRemnant = recordings.appendingPathComponent(".deleted-\(live.uuidString)-0a1b2c3d")
    let foreign = recordings.appendingPathComponent(".deleted-not-a-meeting")
    let other = recordings.appendingPathComponent(".something-else")
    for folder in [liveRemnant, foreign, other] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: folder.appendingPathComponent("meeting.wav"))
    }

    #expect(store.sweepSetAsideRecordings() == nil)

    #expect(setAsideFolders(in: root) == [".deleted-\(live.uuidString)-0a1b2c3d", ".deleted-not-a-meeting", ".something-else"])
}

// F579: one batch, three outcomes — a folder kept, an entry-only delete, and a shred pass with
// something to say — and every one of them is said.
@MainActor
@Test("A batch delete that keeps a folder and removes an entry only says both, and the shred pass adds to them (F579)")
func batchDeleteSaysEveryOutcome() throws {
    let (store, root) = try makeLibrary("compose")
    defer { try? FileManager.default.removeItem(at: root) }
    // An earlier deletion, two weeks old, still held by a torn quarantine copy of the index: the
    // shred pass that follows this delete reports that copy.
    let earlier = UUID()
    store.upsert(MeetingRecord(id: earlier, title: "Old standup", status: .completed, transcriptText: "the confidential-kestrel figures"))
    let index = try Data(contentsOf: root.appendingPathComponent("meetings.json"))
    store.delete(ids: [earlier])
    let quarantine = root.appendingPathComponent("meetings.unreadable-20260901T100000Z.json")
    try index.prefix(index.count - 10).write(to: quarantine)
    let twoWeeksAgo = Int(Date().timeIntervalSince1970) - 2 * Int(MeetingStore.shredGracePeriod)
    try JSONEncoder().encode([earlier.uuidString: twoWeeksAgo])
        .write(to: root.appendingPathComponent("meetings.pending-shred.json"))
    let relaunched = MeetingStore(rootDirectory: root)

    let (kept, _) = try addMeeting(relaunched, root: root, title: "Kept review")
    let entryOnly = UUID()
    relaunched.upsert(MeetingRecord(id: entryOnly, title: "Model link", recordingPath: "Models/large-v3.pt", status: .completed))
    relaunched.setRecordingDirectoryAside = { folder in
        guard !folder.lastPathComponent.contains(kept.uuidString) else { throw CocoaError(.fileWriteNoPermission) }
        return try MeetingStore.moveAsideForDeletion(folder)
    }

    #expect(relaunched.delete(ids: [kept, entryOnly]) == [entryOnly])

    let message = try #require(relaunched.storageErrorMessage)
    #expect(message.contains("Kept review"), "the kept folder was not said: \(message)")
    #expect(message.contains("no files were deleted from disk"), "the entry-only delete was not said: \(message)")
    #expect(message.contains("meetings.unreadable-20260901T100000Z.json"), "the shred pass was not said: \(message)")
}

// The sweep is reached from the launch (`performStartupRecovery`), and what it cannot remove is in
// the launch's summary.
@MainActor
@Test("The launch removes what deletes set aside, and names what it still cannot remove (F609)")
func launchSweepsSetAsideFoldersAndNamesTheStuckOnes() async throws {
    let (store, root) = try makeLibrary("launch")
    defer { try? FileManager.default.removeItem(at: root) }
    let recordings = root.appendingPathComponent("Recordings")
    let removable = ".deleted-\(UUID().uuidString)-0a1b2c3d"
    let stubborn = ".deleted-\(UUID().uuidString)-4e5f6a7b"
    for name in [removable, stubborn] {
        let folder = recordings.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: folder.appendingPathComponent("meeting.wav"))
    }
    store.removeRecordingDirectory = { folder in
        guard folder.lastPathComponent != stubborn else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.removeItem(at: folder)
    }
    let model = AppModel(store: store, recorder: AudioCaptureEngine(),
                         defaults: try #require(UserDefaults(suiteName: testSuiteName())),
                         whisperExecutable: { nil }, qwenInstalled: { false })

    await model.performStartupRecovery()

    #expect(setAsideFolders(in: root) == [stubborn])
    let said = try #require(model.alertMessage, "the launch said nothing about the folder it could not remove")
    #expect(said.contains("Recordings/\(stubborn)"), "\(said)")
}
