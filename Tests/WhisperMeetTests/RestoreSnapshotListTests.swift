import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F855 — the restore safety copies, listed in Settings with their date and size, each removable on
// request; nothing removes one automatically.
//
// A backup restore keeps the library it replaced in a hidden `.pre-restore-<epoch>` folder inside the
// library, so the restore can be undone by hand. F664 removes a deleted meeting's recording from them
// a week after the delete, but only for deletions it sees queued; meetings deleted before that left no
// record, so their audio and notes.md stayed in older safety copies, out of sight. Decided 2026-10-07
// by the user (asked by whisper-dfd4, three options — list in Settings / expire after 30 days / leave
// as is): Settings ▸ Meeting library lists each safety folder with its date and size and a Remove
// button; nothing is removed automatically.

private func writeFile(_ url: URL, bytes: Int) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(count: bytes).write(to: url)
}

@MainActor
private struct Library {
    let root: URL
    let model: AppModel
    var store: MeetingStore { model.store }
    func snapshot(_ epoch: Int) -> URL { root.appendingPathComponent(".pre-restore-\(epoch)", isDirectory: true) }
}

@MainActor
private func makeLibrary(_ label: String, healthy: Bool = true) throws -> Library {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F855-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    if healthy {
        let seed = MeetingStore(rootDirectory: root)
        seed.upsert(MeetingRecord(id: UUID(), title: "Standup", status: .completed))
    } else {
        // Neither index copy reads: the library opens read-only.
        try Data("broken-primary".utf8).write(to: root.appendingPathComponent("meetings.json"))
        try Data("broken-backup".utf8).write(to: root.appendingPathComponent("meetings.backup.json"))
    }
    // Two safety copies as a restore leaves them: index files and the recording folders it overwrote.
    let older = root.appendingPathComponent(".pre-restore-1790000000", isDirectory: true)
    try writeFile(older.appendingPathComponent("meetings.json"), bytes: 1_000)
    try writeFile(older.appendingPathComponent("Recordings/\(UUID().uuidString)/meeting.wav"), bytes: 40_000)
    try writeFile(older.appendingPathComponent("Recordings/\(UUID().uuidString)/notes.md"), bytes: 500)
    let newer = root.appendingPathComponent(".pre-restore-1790000500", isDirectory: true)
    try writeFile(newer.appendingPathComponent("meetings.json"), bytes: 2_000)
    let defaults = try #require(UserDefaults(suiteName: "F855.\(UUID().uuidString)"))
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    return Library(root: root, model: model)
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

@MainActor
@Test("Settings lists each restore safety copy, newest first, with its date and size (F855)")
func theSafetyCopiesAreListedWithDateAndSize() throws {
    let library = try makeLibrary("listed")
    defer { try? FileManager.default.removeItem(at: library.root) }
    // Not safety copies a restore made: a link where one would be, and a plain file with the name.
    let elsewhere = library.root.appendingPathComponent("Elsewhere", isDirectory: true)
    try writeFile(elsewhere.appendingPathComponent("big.bin"), bytes: 900_000)
    try FileManager.default.createSymbolicLink(at: library.snapshot(1_790_000_900), withDestinationURL: elsewhere)
    try Data("x".utf8).write(to: library.snapshot(1_790_001_000))
    // And a link inside a real one is not followed when it is measured.
    try FileManager.default.createSymbolicLink(
        at: library.snapshot(1_790_000_500).appendingPathComponent("outside"), withDestinationURL: elsewhere
    )

    library.model.refreshRestoreSnapshots()

    let listed = library.model.restoreSnapshots
    #expect(listed.map(\.name) == [".pre-restore-1790000500", ".pre-restore-1790000000"], "\(listed.map(\.name))")
    #expect(listed.map(\.createdAt) == [Date(timeIntervalSince1970: 1_790_000_500), Date(timeIntervalSince1970: 1_790_000_000)])
    let sizes: [Int64] = [2_000, 41_500]
    #expect(listed.map(\.byteCount) == sizes, "a link was followed, or a file missed: \(listed.map(\.byteCount))")
    // The row says both, in the forms the app uses elsewhere.
    for snapshot in listed {
        let label = AppModel.restoreSnapshotLabel(snapshot)
        #expect(label.contains(ByteCountFormatter.string(fromByteCount: snapshot.byteCount, countStyle: .file)), "\(label)")
        let date = try #require(snapshot.createdAt)
        #expect(label.contains(DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)), "\(label)")
    }
}

@MainActor
@Test("Remove asks first, says the deletion is permanent, then deletes only that safety copy (F855)")
func removingASafetyCopyIsConfirmedAndRemovesOnlyIt() throws {
    let library = try makeLibrary("remove")
    defer { try? FileManager.default.removeItem(at: library.root) }
    library.model.refreshRestoreSnapshots()
    let older = try #require(library.model.restoreSnapshots.first { $0.name == ".pre-restore-1790000000" })

    library.model.requestRestoreSnapshotRemoval(older)
    #expect(library.model.pendingRestoreSnapshotRemoval == older, "nothing asked first")
    let message = AppModel.restoreSnapshotRemovalMessage(older)
    #expect(message.contains("permanently"), "\(message)")
    #expect(message.contains(ByteCountFormatter.string(fromByteCount: older.byteCount, countStyle: .file)), "\(message)")
    // An unconfirmed call is the seam the dialog hangs on, and does nothing.
    library.model.removeRestoreSnapshot(confirmed: false)
    #expect(exists(library.snapshot(1_790_000_000)), "removed without being confirmed")

    library.model.removeRestoreSnapshot(confirmed: true)

    #expect(!exists(library.snapshot(1_790_000_000)), "the confirmed safety copy is still there")
    #expect(exists(library.snapshot(1_790_000_500).appendingPathComponent("meetings.json")), "another safety copy was touched")
    #expect(MeetingStore(rootDirectory: library.root).meetings.map(\.title) == ["Standup"], "the library was touched")
    #expect(library.model.restoreSnapshots.map(\.name) == [".pre-restore-1790000500"], "the list was not refreshed")
    #expect(library.model.pendingRestoreSnapshotRemoval == nil)
}

@MainActor
@Test("A safety copy cannot be removed while the library is read-only or a restore is running (F855)")
func removingASafetyCopyIsRefusedWhenItMayBeNeeded() throws {
    let readOnly = try makeLibrary("read-only", healthy: false)
    defer { try? FileManager.default.removeItem(at: readOnly.root) }
    try #require(readOnly.store.isDegraded, "the fixture is not read-only")
    readOnly.model.refreshRestoreSnapshots()
    let snapshot = try #require(readOnly.model.restoreSnapshots.first)

    readOnly.model.requestRestoreSnapshotRemoval(snapshot)
    readOnly.model.removeRestoreSnapshot(confirmed: true)

    #expect(exists(readOnly.snapshot(1_790_000_000)) && exists(readOnly.snapshot(1_790_000_500)),
            "a safety copy was removed from a read-only library")
    #expect(readOnly.model.alertMessage == ReadOnlyLibraryNotice.restoreSnapshotRemovalUnavailable,
            "\(readOnly.model.alertMessage ?? "nothing was said")")
    #expect(throws: MeetingStoreError.libraryIsReadOnly) { try readOnly.store.removeRestoreSnapshot(named: snapshot.name) }

    let healthy = try makeLibrary("restoring")
    defer { try? FileManager.default.removeItem(at: healthy.root) }
    healthy.model.refreshRestoreSnapshots()
    let other = try #require(healthy.model.restoreSnapshots.first)
    healthy.store.beginLibraryRestore()
    healthy.model.requestRestoreSnapshotRemoval(other)
    healthy.model.removeRestoreSnapshot(confirmed: true)
    #expect(exists(healthy.snapshot(1_790_000_500)), "removed while a restore was running")
    #expect(throws: MeetingStoreError.libraryIsBeingRestored) { try healthy.store.removeRestoreSnapshot(named: other.name) }
    healthy.store.endLibraryRestore()
}

@MainActor
@Test("Remove never acts on a link or on anything that is not a safety copy (F855)")
func removeRefusesWhatIsNotASafetyCopy() throws {
    let library = try makeLibrary("not-a-copy")
    defer { try? FileManager.default.removeItem(at: library.root) }
    let elsewhere = library.root.appendingPathComponent("Elsewhere", isDirectory: true)
    try writeFile(elsewhere.appendingPathComponent("keep.bin"), bytes: 10)
    try FileManager.default.createSymbolicLink(at: library.snapshot(1_790_000_900), withDestinationURL: elsewhere)

    for name in [".pre-restore-1790000900", "Recordings", "../Elsewhere", ".pre-restore-1790000000/Recordings"] {
        #expect(throws: (any Error).self, "\(name) was accepted") { try library.store.removeRestoreSnapshot(named: name) }
    }
    #expect(exists(elsewhere.appendingPathComponent("keep.bin")), "removed through a link")
    #expect(exists(library.snapshot(1_790_000_900)), "the link itself was removed")
    #expect(exists(library.snapshot(1_790_000_000).appendingPathComponent("Recordings")))
}

@MainActor
@Test("A safety copy that cannot be removed is reported by name, and stays listed (F855)")
func aSafetyCopyThatCannotBeRemovedIsReported() throws {
    let library = try makeLibrary("stuck")
    let recordings = library.snapshot(1_790_000_000).appendingPathComponent("Recordings", isDirectory: true)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recordings.path)
        try? FileManager.default.removeItem(at: library.root)
    }
    library.model.refreshRestoreSnapshots()
    let older = try #require(library.model.restoreSnapshots.first { $0.name == ".pre-restore-1790000000" })
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: recordings.path)

    library.model.requestRestoreSnapshotRemoval(older)
    library.model.removeRestoreSnapshot(confirmed: true)

    let message = try #require(library.model.alertMessage, "a failed removal said nothing")
    #expect(message.contains(".pre-restore-1790000000") && message.contains("could not be removed"), "\(message)")
    #expect(library.model.restoreSnapshots.contains { $0.name == ".pre-restore-1790000000" },
            "what is left of it is no longer listed")
}

@MainActor
@Test("Remove is offered only for a safety copy the list showed (F855)")
func removeActsOnlyOnAListedSafetyCopy() throws {
    let library = try makeLibrary("unlisted")
    defer { try? FileManager.default.removeItem(at: library.root) }
    // Never listed: refreshRestoreSnapshots() was not called, so the user has not seen it.
    let unseen = MeetingStore.RestoreSnapshot(name: ".pre-restore-1790000000", createdAt: nil, byteCount: 0)
    library.model.requestRestoreSnapshotRemoval(unseen)
    library.model.removeRestoreSnapshot(confirmed: true)
    #expect(exists(library.snapshot(1_790_000_000)), "removed a safety copy the user was never shown")
}

private let legacyIndex = #"[{"id":"4B0C2F10-0000-4000-8000-000000000855","title":"From the old backup","createdAt":"2026-01-05T10:00:00Z","duration":60,"recordingPath":"","status":"recorded","transcriptText":"","segments":[]}]"#

/// The list is read when Settings shows it; a restore made while it is open adds a safety copy, so the
/// restore refreshes it rather than leaving a list that omits the newest one.
@MainActor
@Test("A restore's new safety copy appears in the list straight away (F855)")
func aRestoreListsItsOwnSafetyCopy() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F855-restore-\(UUID().uuidString)", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "F855.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(store: MeetingStore(rootDirectory: library), recorder: AudioCaptureEngine(), defaults: defaults)
    model.store.upsert(MeetingRecord(id: UUID(), title: "Live", status: .recorded))
    model.refreshRestoreSnapshots()
    try #require(model.restoreSnapshots.isEmpty)

    let generation = root
        .appendingPathComponent("Dest/\(BackupCoordinator.managedSubfolder)/1700000000", isDirectory: true)
    try FileManager.default.createDirectory(at: generation, withIntermediateDirectories: true)
    try Data(legacyIndex.utf8).write(to: generation.appendingPathComponent("meetings.json"))
    try Data().write(to: generation.appendingPathComponent(BackupCoordinator.completionMarker))
    await model.requestLibraryRestore(from: generation)
    await model.performLibraryRestore(confirmed: true, acceptingUnverifiedBackup: true)?.value
    try #require(!model.store.isDegraded, "precondition: the restored library opened as \(model.store.health)")

    let onDisk = try FileManager.default.contentsOfDirectory(atPath: library.path).filter { $0.hasPrefix(".pre-restore-") }
    #expect(model.restoreSnapshots.map(\.name) == onDisk, "listed \(model.restoreSnapshots.map(\.name)), on disk \(onDisk)")
}

// The list and its Remove are a Settings section this target cannot render (F174): asserted against
// ContentView's comment-stripped source, in the Meeting library section, as F540 and F833 are.
@Test("The Meeting library section lists the safety copies, with Remove gated and confirmed (F855)")
func theSafetyCopyListIsWiredIntoTheMeetingLibrarySection() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let header = try #require(source.range(of: "Section(header: Label(\"Meeting library\""))
    let rest = source[header.upperBound...]
    let section = String(rest[..<(rest.range(of: "Section(header:")?.lowerBound ?? rest.endIndex)])
    for needle in [
        "ForEach(model.restoreSnapshots)",
        "AppModel.restoreSnapshotLabel(snapshot)",
        "model.requestRestoreSnapshotRemoval(snapshot)",
        ".disabled(model.libraryReadOnlyFootnote != nil || model.isRestoringLibrary)",
        "Text(ReadOnlyLibraryNotice.restoreSnapshotRemovalUnavailable)",
        "model.refreshRestoreSnapshots()",
        "model.pendingRestoreSnapshotRemoval != nil",
        "model.removeRestoreSnapshot(confirmed: true)",
        "AppModel.restoreSnapshotRemovalMessage(",
    ] {
        #expect(section.contains(needle), "the Meeting library section lacks \(needle)")
    }
}
