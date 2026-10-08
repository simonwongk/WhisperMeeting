import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F146 — deleting a meeting must not silently orphan its audio: if the recording folder can't be
// removed, keep the meeting in the index and surface the error instead of half-deleting.
@MainActor
@Test("Delete keeps the meeting and reports the error when the recording can't be removed (F146)")
func deleteSurfacesRemovalFailure() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeleteFail-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(rootDirectory: root)
    let id = UUID()
    store.upsert(MeetingRecord(id: id, title: "M", recordingPath: "Recordings/\(id.uuidString)/meeting.wav", status: .completed))

    struct RemovalError: Error {}
    store.removeRecordingDirectory = { _ in throw RemovalError() }

    store.delete(id: id)

    #expect(store.meeting(id: id) != nil)                 // not half-deleted
    #expect(store.storageErrorMessage != nil)             // failure surfaced
}

@MainActor
@Test("Delete removes the meeting on successful recording removal (F146)")
func deleteSucceedsNormally() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeleteOK-\(UUID().uuidString)")
    let id = UUID()
    let dir = root.appendingPathComponent("Recordings/\(id.uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: dir.appendingPathComponent("meeting.wav"))
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(rootDirectory: root)
    store.upsert(MeetingRecord(id: id, title: "M", recordingPath: "Recordings/\(id.uuidString)/meeting.wav", status: .completed))

    store.delete(id: id)

    #expect(store.meeting(id: id) == nil)                                       // removed from index
    #expect(!FileManager.default.fileExists(atPath: dir.path))                  // audio removed
}

// F148 #6 — a corrupt/tampered recordingPath with `../` must never delete files outside the library.
@MainActor
@Test("Delete never removes a directory outside the library on a traversal path (F148 #6)")
func deleteRefusesPathTraversal() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("DeleteTraversal-\(UUID().uuidString)")
    let root = tmp.appendingPathComponent("library")
    let victim = tmp.appendingPathComponent("victim")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
    try Data("precious".utf8).write(to: victim.appendingPathComponent("file.txt"))
    defer { try? FileManager.default.removeItem(at: tmp) }

    let store = MeetingStore(rootDirectory: root)
    let id = UUID()
    // recordingPath escapes the library up to ../victim/meeting.wav.
    store.upsert(MeetingRecord(id: id, title: "Evil", recordingPath: "../victim/meeting.wav", status: .completed))

    store.delete(id: id)

    #expect(FileManager.default.fileExists(atPath: victim.appendingPathComponent("file.txt").path)) // untouched
    #expect(store.meeting(id: id) == nil)                                                            // entry removed
    #expect(store.storageErrorMessage != nil)                                                        // explained
}

// F148 #6 — an empty recordingPath resolved its folder to the library root's parent, and a delete
// must never remove the library. Since F576 the only folder it may remove is the meeting's own
// `Recordings/<id>`, which this fixture does not have, so nothing on disk is deleted.
@MainActor
@Test("Delete never removes the library root on an empty recordingPath (F148 #6)")
func deleteRefusesRootPath() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeleteRoot-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("index".utf8).write(to: root.appendingPathComponent("marker.txt"))
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(rootDirectory: root)
    let id = UUID()
    store.upsert(MeetingRecord(id: id, title: "NoPath", recordingPath: "", status: .recorded))

    store.delete(id: id)

    #expect(FileManager.default.fileExists(atPath: root.path))                               // library intact
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("marker.txt").path))
    #expect(store.meeting(id: id) == nil)
}

// F452 — the containment check above stops a path from leaving the library, and excluded only the
// root itself inside it. A `recordingPath` one level deep resolves its folder to a directory every
// other meeting, model or runtime shares, and the delete removed that directory whole.
private let foreignRecordingPaths = [
    "Recordings/meeting.wav",          // one level deep: the "folder" is all of Recordings
    "Models/large-v3.pt",              // the downloaded models
    "Recordings/../Runtime/whisper",   // the installed runtime, reached through `..`
    "Recordings/{other}/meeting.wav",  // another meeting's own folder
]

@MainActor
@Test(
    "Delete removes only the meeting's own Recordings/<id> folder, never a shared one (F452)",
    arguments: foreignRecordingPaths, [false, true]
)
func deleteRemovesOnlyTheMeetingsOwnFolder(recordingPath template: String, throughTheUI: Bool) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeleteShared-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(rootDirectory: root)

    // Everything a folder resolved one level too shallow would take with it.
    let other = UUID()
    let otherAudio = root.appendingPathComponent("Recordings/\(other.uuidString)/meeting.wav")
    let model = root.appendingPathComponent("Models/large-v3.pt")
    let runtime = root.appendingPathComponent("Runtime/whisper")
    for file in [otherAudio, model, runtime] {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("keep".utf8).write(to: file)
    }
    store.upsert(MeetingRecord(
        id: other, title: "Other", recordingPath: "Recordings/\(other.uuidString)/meeting.wav",
        status: .completed
    ))
    let doomed = MeetingRecord(
        title: "Doomed",
        recordingPath: template.replacingOccurrences(of: "{other}", with: other.uuidString),
        status: .completed
    )
    store.upsert(doomed)

    if throughTheUI {
        let defaults = try #require(UserDefaults(suiteName: testSuiteName()))
        AppModel(store: store, recorder: AudioCaptureEngine(), defaults: defaults)
            .deleteMeetings(ids: [doomed.id])
    } else {
        store.delete(id: doomed.id)
    }

    for file in [otherAudio, model, runtime] {
        #expect(
            FileManager.default.fileExists(atPath: file.path),
            "\(file.path) was removed with a meeting it did not belong to"
        )
    }
    #expect(store.meeting(id: doomed.id) == nil, "the entry itself is still removed")
    #expect(store.meeting(id: other) != nil)
    #expect(store.storageErrorMessage != nil, "and the user is told no files were deleted")
}

// The other direction: a fix that compared folder names as strings would refuse a meeting whose
// folder was named in lowercase — `FolderRebuild` keeps the folder's own spelling in
// `recordingPath` while `UUID(uuidString:)` accepts either case — and leave its audio behind.
@MainActor
@Test("A meeting whose own folder is named in lowercase still has it removed (F452)")
func deleteRemovesAnOwnFolderNamedInLowercase() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeleteLowercase-\(UUID().uuidString)", isDirectory: true)
    let id = UUID()
    let name = id.uuidString.lowercased()
    let folder = root.appendingPathComponent("Recordings/\(name)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: folder.appendingPathComponent("meeting.wav"))
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(rootDirectory: root)
    store.upsert(MeetingRecord(
        id: id, title: "Rebuilt", recordingPath: "Recordings/\(name)/meeting.wav", status: .recorded
    ))

    store.delete(id: id)

    #expect(!FileManager.default.fileExists(atPath: folder.path))
    #expect(store.meeting(id: id) == nil)
    #expect(store.storageErrorMessage == nil)
}

// F576 — the one record the app writes with no `recordingPath` is F311's "Interrupted import from
// <host>", and its message tells the user to delete it. With no path to derive a folder from, the
// delete took the index entry only: `Recordings/<id>` stayed, `orphanedRecordings()` listed it again
// because the index no longer had its id, and the next launch indexed the same entry again.
private func makeInterruptedImportFolder(in root: URL, named name: String) throws -> URL {
    let folder = root.appendingPathComponent("Recordings/\(name)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // The shape a crash mid-download leaves — a sidecar and yt-dlp's partial file. The store's
    // delete reads neither, so the sidecar's contents do not matter here.
    try Data("{}".utf8).write(to: folder.appendingPathComponent(MediaSource.sidecarFilename))
    try Data("partial bytes".utf8).write(to: folder.appendingPathComponent("recording.m4a.part"))
    return folder
}

@MainActor
@Test("Deleting a meeting with no recording path removes its own Recordings/<id> folder (F576)")
func deleteRemovesTheOwnFolderOfAMeetingWithNoRecordingPath() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeleteNoPath-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let folder = try makeInterruptedImportFolder(in: root, named: id.uuidString)
    let store = MeetingStore(rootDirectory: root)
    store.upsert(MeetingRecord(id: id, title: "Interrupted import from example.com", status: .failed))
    try #require(store.meeting(id: id)?.recordingPath == "", "fixture: the record has no recording path")

    #expect(store.delete(ids: [id]) == [id])

    #expect(!FileManager.default.fileExists(atPath: folder.path), "the folder and its partial download survived")
    #expect(try store.orphanedRecordings().isEmpty, "the folder is listed again, so the next launch re-indexes it")
    #expect(store.storageErrorMessage == nil, "\(store.storageErrorMessage ?? "")")
}

// The spelling half. `orphanedRecordings()` lists a folder under any name `UUID(uuidString:)`
// parses to the id, lowercase included. On the default case-insensitive volume `Recordings/<UPPER>`
// names a lowercase folder too, so removing it proves nothing about spelling here; on a case-sensitive
// volume only the folder's own name removes it. So the name handed to the remover is the assertion.
@MainActor
@Test("A meeting with no recording path has its own folder removed by the name it has on disk (F576)")
func deleteNamesTheOwnFolderOfAMeetingWithNoRecordingPathAsItIsSpelledOnDisk() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeleteNoPathLowercase-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let name = id.uuidString.lowercased()
    let folder = try makeInterruptedImportFolder(in: root, named: name)
    let store = MeetingStore(rootDirectory: root)
    store.upsert(MeetingRecord(id: id, title: "Interrupted import from example.com", status: .failed))
    var removed: [String] = []
    store.removeRecordingDirectory = { url in
        removed.append(url.lastPathComponent)
        try FileManager.default.removeItem(at: url)
    }

    #expect(store.delete(ids: [id]) == [id])

    #expect(removed == [name], "the remover was handed \(removed), not the folder's own name")
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    #expect(try store.orphanedRecordings().isEmpty)
}
