import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F664 — a restore's `.pre-restore-*` snapshot keeps a copy of every recording the restore
// overwrote: the audio and its `notes.md`, which holds the transcript and summary. F457's week-later
// shred cleaned the snapshot's index files and left those folders alone, so a meeting deleted after a
// restore kept its audio and text there indefinitely, out of sight in the app.
//
// Decided 2026-10-07 by the user (asked by whisper-dfd4, three options): when a deleted meeting's
// one-week grace ends, the shred also removes that meeting's `Recordings/<id>/` copy from every
// `.pre-restore-*` folder, as the index shred does. Never a meeting that is live again; a copy that
// cannot be removed is named and retried, F668's shape.

private let week = Int(MeetingStore.shredGracePeriod)

private struct Library {
    let root: URL
    let store: MeetingStore
    let kept: UUID
    let secret: UUID
    /// The two restore snapshots, each holding a copy of both meetings' recording folders.
    let snapshots: [URL]

    func copy(of id: UUID, in snapshot: URL, lowercased: Bool = false) -> URL {
        snapshot.appendingPathComponent("Recordings", isDirectory: true)
            .appendingPathComponent(lowercased ? id.uuidString.lowercased() : id.uuidString, isDirectory: true)
    }
}

/// A meeting folder as a restore's snapshot holds it: the files it overwrote, `notes.md` included.
private func writeRecordingCopy(_ folder: URL, text: String) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(count: 4_096).write(to: folder.appendingPathComponent("meeting.wav"))
    try Data("# Notes\n\n\(text)\n".utf8).write(to: folder.appendingPathComponent("notes.md"))
}

@MainActor
private func makeLibrary(_ label: String) throws -> Library {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F664-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = MeetingStore(rootDirectory: root)
    let kept = UUID(), secret = UUID()
    for (id, title) in [(kept, "Standup"), (secret, "Board review")] {
        let path = "Recordings/\(id.uuidString)/meeting.wav"
        try writeRecordingCopy(root.appendingPathComponent("Recordings/\(id.uuidString)"), text: title)
        store.upsert(MeetingRecord(id: id, title: title, recordingPath: path, status: .completed,
                                   transcriptText: id == secret ? "the confidential-kestrel figures" : "ordinary"))
    }
    var snapshots: [URL] = []
    for (index, epoch) in [1_790_000_000, 1_790_000_500].enumerated() {
        let snapshot = root.appendingPathComponent(".pre-restore-\(epoch)", isDirectory: true)
        // The second snapshot names its folders in lower case: the shred matches the id, not a spelling.
        for id in [kept, secret] {
            let folder = snapshot.appendingPathComponent("Recordings", isDirectory: true)
                .appendingPathComponent(index == 1 ? id.uuidString.lowercased() : id.uuidString, isDirectory: true)
            try writeRecordingCopy(folder, text: id == secret ? "the confidential-kestrel figures" : "ordinary")
        }
        snapshots.append(snapshot)
    }
    return Library(root: root, store: store, kept: kept, secret: secret, snapshots: snapshots)
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

@MainActor
@Test("When a deleted meeting's week ends its recording copy leaves every restore snapshot, and nothing else does (F664)")
func theWeekLaterShredRemovesTheSnapshotsRecordingCopies() throws {
    let library = try makeLibrary("removed")
    defer { try? FileManager.default.removeItem(at: library.root) }
    library.store.delete(id: library.secret)
    let deletedAt = try #require(library.store.pendingShreds[library.secret])

    // Inside the week: the copy is what undoing the restore by hand would bring back, so it stays.
    _ = library.store.processPendingShreds(now: deletedAt + 3_600)
    #expect(exists(library.copy(of: library.secret, in: library.snapshots[0])), "removed inside the week")

    #expect(library.store.processPendingShreds(now: deletedAt + week) == [library.secret])

    #expect(!exists(library.copy(of: library.secret, in: library.snapshots[0])),
            "the deleted meeting's audio and notes.md are still in the first snapshot")
    #expect(!exists(library.copy(of: library.secret, in: library.snapshots[1], lowercased: true)),
            "the deleted meeting's copy is still in the second snapshot")
    for snapshot in library.snapshots {
        let lowercased = snapshot == library.snapshots[1]
        #expect(exists(library.copy(of: library.kept, in: snapshot, lowercased: lowercased)
            .appendingPathComponent("notes.md")), "a live meeting's copy was touched in \(snapshot.lastPathComponent)")
    }
    #expect(exists(library.root.appendingPathComponent("Recordings/\(library.kept.uuidString)/meeting.wav")))
    #expect(library.store.storageErrorMessage == nil, "\(library.store.storageErrorMessage ?? "")")
    // Nothing is left queued once every copy is gone.
    let queue = library.root.appendingPathComponent("meetings.pending-shred.json")
    let raw = (try? JSONDecoder().decode([String: Int].self, from: Data(contentsOf: queue))) ?? [:]
    #expect(raw.isEmpty, "\(raw)")
}

@MainActor
@Test("A snapshot's recording copy that cannot be removed is named by its path, stays queued, and goes at a later launch (F664)")
func aRecordingCopyThatCannotBeRemovedIsRetried() throws {
    let library = try makeLibrary("stuck")
    let recordings = library.snapshots[0].appendingPathComponent("Recordings", isDirectory: true)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recordings.path)
        try? FileManager.default.removeItem(at: library.root)
    }
    library.store.delete(id: library.secret)
    let deletedAt = try #require(library.store.pendingShreds[library.secret])
    // A transient refusal: nothing can be removed from this snapshot's Recordings folder for one pass.
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: recordings.path)

    #expect(library.store.processPendingShreds(now: deletedAt + week) == [library.secret])

    let stuck = ".pre-restore-1790000000/Recordings/\(library.secret.uuidString)"
    let message = try #require(library.store.storageErrorMessage, "a copy that could not be removed was not mentioned")
    #expect(message.contains(stuck), "\(message)")
    #expect(exists(library.copy(of: library.secret, in: library.snapshots[0])), "fixture: the copy could not be removed")
    #expect(!exists(library.copy(of: library.secret, in: library.snapshots[1], lowercased: true)),
            "one snapshot's failure stopped the other from being cleaned")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recordings.path)

    // Tried again at the next launch, and then gone.
    let relaunched = MeetingStore(rootDirectory: library.root)
    _ = relaunched.processPendingShreds(now: deletedAt + week + 60)
    #expect(!exists(library.copy(of: library.secret, in: library.snapshots[0])),
            "the copy that could not be removed once was never looked at again")
    #expect(relaunched.storageErrorMessage == nil, "\(relaunched.storageErrorMessage ?? "")")
}

/// "Never touch a meeting that is still live" includes one whose audio is the snapshot's copy: an
/// index edited by hand to point a live meeting at a file inside `.pre-restore-*`.
@MainActor
@Test("A snapshot folder a live meeting's recording path points into is kept, even under a deleted meeting's id (F664)")
func aSnapshotFolderALiveMeetingUsesIsKept() throws {
    let library = try makeLibrary("pointed")
    defer { try? FileManager.default.removeItem(at: library.root) }
    let pointed = library.copy(of: library.secret, in: library.snapshots[0])
    let path = ".pre-restore-1790000000/Recordings/\(library.secret.uuidString)/meeting.wav"
    library.store.upsert(MeetingRecord(id: UUID(), title: "Points into the snapshot", recordingPath: path,
                                       status: .completed))
    library.store.delete(id: library.secret)
    let deletedAt = try #require(library.store.pendingShreds[library.secret])

    _ = library.store.processPendingShreds(now: deletedAt + week)

    #expect(exists(pointed.appendingPathComponent("meeting.wav")), "a live meeting's audio was removed")
    #expect(!exists(library.copy(of: library.secret, in: library.snapshots[1], lowercased: true)),
            "the other snapshot's copy, which nothing live uses, should still go")
}

/// A restore writes real folders; a link where one should be was put there by something else, and
/// removing through it would delete wherever it points.
@MainActor
@Test("A snapshot whose Recordings is a link is not followed (F664)")
func aLinkedSnapshotRecordingsFolderIsNotFollowed() throws {
    let library = try makeLibrary("linked")
    defer { try? FileManager.default.removeItem(at: library.root) }
    let elsewhere = library.root.appendingPathComponent("Elsewhere", isDirectory: true)
    try writeRecordingCopy(elsewhere.appendingPathComponent(library.secret.uuidString), text: "not a snapshot")
    let recordings = library.snapshots[0].appendingPathComponent("Recordings", isDirectory: true)
    try FileManager.default.removeItem(at: recordings)
    try FileManager.default.createSymbolicLink(at: recordings, withDestinationURL: elsewhere)
    library.store.delete(id: library.secret)
    let deletedAt = try #require(library.store.pendingShreds[library.secret])

    _ = library.store.processPendingShreds(now: deletedAt + week)

    #expect(exists(elsewhere.appendingPathComponent("\(library.secret.uuidString)/notes.md")),
            "a folder outside the snapshot was removed through a link")
    #expect(!exists(library.copy(of: library.secret, in: library.snapshots[1], lowercased: true)))
}

/// F498's rule reaches the snapshots too: a meeting that is in the library again is never stripped.
@MainActor
@Test("A meeting brought back inside its week keeps its recording copies in the restore snapshots (F664)")
func aMeetingThatCameBackKeepsItsSnapshotCopies() throws {
    let library = try makeLibrary("back")
    defer { try? FileManager.default.removeItem(at: library.root) }
    let original = try #require(library.store.meeting(id: library.secret))
    library.store.delete(id: library.secret)
    let deletedAt = try #require(library.store.pendingShreds[library.secret])
    library.store.upsert(original)   // as a restore or a rebuild brings it back, under its old id

    _ = library.store.processPendingShreds(now: deletedAt + week)

    for snapshot in library.snapshots {
        let lowercased = snapshot == library.snapshots[1]
        #expect(exists(library.copy(of: library.secret, in: snapshot, lowercased: lowercased)
            .appendingPathComponent("notes.md")), "a live meeting's copy was removed from \(snapshot.lastPathComponent)")
    }
}
