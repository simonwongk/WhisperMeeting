import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F457 — Forget History, and what the saved history does and does not protect.
//
// Part 1. `forgetIndexHistory()` had no read-only guard, and its button sat outside the read-only
// block, so on a library that could not be read it deleted every retained generation — exactly what
// Recover Library restores from — under a dialog that said nothing was lost. It also deleted every
// conflict branch, a losing writer's work that exists nowhere else, without naming one.
//
// Part 2. Quarantine copies (`meetings.unreadable-*.json`, `meetings.backup.unreadable-*.json`) and a
// restore's `.pre-restore-*/` snapshot hold the whole index's text, and neither the week-later shred
// nor Forget History knew they existed.
//
// Part 3 (the user's answer of 2026-09-24: correct the caption). The caption promised that "a
// mistaken delete can still be undone" within the week; a healthy library has no in-app undo for a
// deleted meeting, and Recover Library appears only when the library cannot be read.

private let week = Int(MeetingStore.shredGracePeriod)

private func makeRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F457-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func historyNames(_ root: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("meetings.history").path
    )) ?? []
}

/// A library with retained history, then its primary truncated so it opens read-only from the
/// backup — the state in which the history is what Recover Library offers.
@MainActor
private func makeReadOnlyLibraryWithHistory() throws -> (MeetingStore, URL) {
    let root = try makeRoot("readonly")
    let seed = MeetingStore(rootDirectory: root)
    for title in ["Standup", "Planning", "Retro"] {
        seed.upsert(MeetingRecord(id: UUID(), title: title, status: .completed, transcriptText: title))
    }
    try Data("truncated-primary".utf8).write(to: root.appendingPathComponent("meetings.json"))
    let store = MeetingStore(rootDirectory: root)
    try #require(store.isDegraded)
    return (store, root)
}

@MainActor
@Test("Forget History is refused while the library is read-only, and every generation Recover Library needs survives (F457)")
func forgetHistoryIsRefusedOnAReadOnlyLibrary() throws {
    let (store, root) = try makeReadOnlyLibraryWithHistory()
    defer { try? FileManager.default.removeItem(at: root) }
    let before = try store.indexGenerations()
    try #require(!before.isEmpty, "fixture: the read-only library has history to recover from")

    _ = store.forgetIndexHistory()

    #expect(try store.indexGenerations() == before, "Forget History deleted what Recover Library restores from")
    #expect(store.storageErrorMessage == ReadOnlyLibraryNotice.mutationRefused)
}

/// Two copies of the app, one of which lost a save: its body is a `conflict-` branch.
@MainActor
private func makeLibraryWithAConflictBranch() throws -> (MeetingStore, URL) {
    let root = try makeRoot("conflict")
    let id = UUID()
    let seed = MeetingStore(rootDirectory: root)
    seed.upsert(MeetingRecord(id: id, title: "Standup", status: .completed))
    let store = MeetingStore(rootDirectory: root)
    let rival = BackupJSONStore<[MeetingRecord]>(
        primaryURL: root.appendingPathComponent("meetings.json"),
        backupURL: root.appendingPathComponent("meetings.backup.json"),
        writer: "ffff9999",
        recordCount: { $0.count }
    )
    let seen = try #require(try rival.load())
    try rival.save(seen.value + [MeetingRecord(id: UUID(), title: "The other copy's", status: .completed)],
                   expecting: seen.token)
    store.update(id: id) { $0.title = "This copy's rename, which lost" }
    store.discardConflictedEdit()
    try #require(historyNames(root).contains { $0.hasPrefix("conflict-") }, "fixture: a lost save leaves a branch")
    return (store, root)
}

@MainActor
@Test("Forget History keeps conflict copies unless they are named and chosen (F457)")
func forgetHistoryKeepsConflictCopiesByDefault() throws {
    let (store, root) = try makeLibraryWithAConflictBranch()
    defer { try? FileManager.default.removeItem(at: root) }
    let branches = historyNames(root).filter { $0.hasPrefix("conflict-") }

    _ = store.forgetIndexHistory()

    #expect(historyNames(root).filter { $0.hasPrefix("conflict-") } == branches,
            "a conflict copy — work that exists nowhere else — was deleted without being named")
    #expect(!historyNames(root).contains { $0.hasPrefix("g-") }, "the generations were not forgotten")
}

@MainActor
@Test("Forget History names the conflict copies it would keep, and removes them only when asked (F457)")
func forgetHistoryNamesAndOptionallyRemovesConflictCopies() throws {
    let (store, root) = try makeLibraryWithAConflictBranch()
    defer { try? FileManager.default.removeItem(at: root) }

    let inventory = store.forgetHistoryInventory()
    #expect(inventory.conflictCopies == 1)
    #expect(ForgetHistoryNotice.dialogMessage(inventory).contains("1 conflict copy"),
            "\(ForgetHistoryNotice.dialogMessage(inventory))")

    let kept = try #require(store.forgetIndexHistory())
    #expect(kept.keptConflictCopies == 1)
    #expect(ForgetHistoryNotice.result(kept).contains("1 conflict copy"), "\(ForgetHistoryNotice.result(kept))")

    let removed = try #require(store.forgetIndexHistory(includingConflictCopies: true))
    #expect(removed.removedConflictCopies == 1)
    #expect(removed.keptConflictCopies == 0)
    #expect(!historyNames(root).contains { $0.hasPrefix("conflict-") })
}

/// A deleted meeting whose text also sits in a quarantine copy and in a restore's snapshot.
@MainActor
private func makeDeleteWithSideCopies() throws -> (MeetingStore, URL, UUID, [URL]) {
    let root = try makeRoot("side")
    let store = MeetingStore(rootDirectory: root)
    let secret = UUID()
    store.upsert(MeetingRecord(id: UUID(), title: "Standup", status: .completed, transcriptText: "ordinary"))
    store.upsert(MeetingRecord(id: secret, title: "Board review", status: .completed,
                               transcriptText: "the confidential-kestrel figures"))
    let index = try Data(contentsOf: root.appendingPathComponent("meetings.json"))
    // What `StoreQuarantine.preserve` leaves beside the index after a divergent or salvaged load,
    // for the primary and for the backup.
    let quarantine = root.appendingPathComponent("meetings.unreadable-20260901T100000Z.json")
    let backupQuarantine = root.appendingPathComponent("meetings.backup.unreadable-20260901T100000Z.json")
    try index.write(to: quarantine)
    try index.write(to: backupQuarantine)
    // What `BackupRestore.apply` keeps after a restore.
    let snapshot = root.appendingPathComponent(".pre-restore-1790000000", isDirectory: true)
    try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
    let snapshotIndex = snapshot.appendingPathComponent("meetings.json")
    try index.write(to: snapshotIndex)
    store.delete(id: secret)
    try #require(store.pendingShreds.keys.contains(secret))
    return (store, root, secret, [quarantine, backupQuarantine, snapshotIndex])
}

@MainActor
@Test("The week-later shred removes the deleted meeting from quarantine copies and restore snapshots too, and keeps the rest (F457)")
func shredReachesQuarantineCopiesAndSnapshots() throws {
    let (store, root, secret, sideCopies) = try makeDeleteWithSideCopies()
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(store.processPendingShreds(now: Int(Date().timeIntervalSince1970) + week + 1) == [secret])

    for url in sideCopies {
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("confidential-kestrel"), "\(url.lastPathComponent) still holds the deleted meeting")
        // Deferred, never destructive: everything else in the copy is still there to recover from.
        #expect(text.contains("Standup"), "\(url.lastPathComponent) lost a meeting nobody deleted")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect((try? decoder.decode([MeetingRecord].self, from: Data(contentsOf: url)))?.count == 1,
                "\(url.lastPathComponent) no longer reads as an index")
    }
}

@MainActor
@Test("Forget History keeps quarantine copies and restore snapshots, and says where they are (F457)")
func forgetHistoryListsTheCopiesItKeeps() throws {
    let (store, root, _, sideCopies) = try makeDeleteWithSideCopies()
    defer { try? FileManager.default.removeItem(at: root) }

    let inventory = store.forgetHistoryInventory()
    #expect(inventory.quarantineCopies.count == 2)
    #expect(inventory.preRestoreSnapshots == [".pre-restore-1790000000"])
    let message = ForgetHistoryNotice.dialogMessage(inventory)
    #expect(message.contains("2 copies set aside"), "\(message)")
    #expect(message.contains("1 copy kept by a restore"), "\(message)")

    let outcome = try #require(store.forgetIndexHistory())

    for url in sideCopies {
        #expect(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) was deleted")
    }
    #expect(ForgetHistoryNotice.result(outcome).contains(".pre-restore-1790000000"), "\(ForgetHistoryNotice.result(outcome))")
    #expect(ForgetHistoryNotice.result(outcome).contains("meetings.unreadable-20260901T100000Z.json"),
            "\(ForgetHistoryNotice.result(outcome))")
}

// MARK: - The surface (no view harness in this target: F174; comments stripped: F285)

@MainActor
@Test("The Forget History button is disabled on a read-only library and its dialog is generated from what is on disk (F457)")
func forgetHistoryControlIsGatedAndHonest() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let button = try #require(source.range(of: "Button(\"Forget History…\""), "the Forget History button moved")
    let tail = String(source[button.lowerBound...].prefix(600))
    #expect(tail.contains(".disabled(model.libraryReadOnlyFootnote != nil)"),
            "the button is offered on a read-only library")
    #expect(tail.contains("ReadOnlyLibraryNotice.forgetHistoryUnavailable"),
            "a disabled button with no reason beside it")
    #expect(source.contains("ForgetHistoryNotice.dialogMessage("), "the dialog no longer names what it keeps")
    #expect(source.contains("forgetIndexHistory(includingConflictCopies: true)"),
            "no way to remove the conflict copies the dialog names")
    #expect(source.contains("ForgetHistoryNotice.result"))
}

@MainActor
@Test("The caption no longer promises an undo for a deleted meeting that nothing in the app offers (F457)")
func forgetHistoryCaptionDoesNotPromiseAnUndo() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(!source.contains("so a mistaken delete can still be undone in between"))
    #expect(source.contains("ForgetHistoryNotice.caption"))
    #expect(ForgetHistoryNotice.caption.contains("no undo"), "\(ForgetHistoryNotice.caption)")
    #expect(ForgetHistoryNotice.caption.contains("Recover Library"), "\(ForgetHistoryNotice.caption)")
}
