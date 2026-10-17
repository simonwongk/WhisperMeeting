import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F580 (the user's decision of 2026-10-16: "Yes, refresh it at once"). Forget History removed every
// saved generation but left `meetings.backup.json` — the index one save behind — so a meeting deleted
// by the most recent save kept its title, transcript and summary there until some later save rotated
// it out. Forget History now makes one ordinary save first, which rotates the current index into the
// backup, and then forgets the history (including the generation that save just kept).

private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F580-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@MainActor
@Test("Forget History refreshes the backup copy, so a just-deleted meeting's text is gone from it too (F580)")
func forgetHistoryRefreshesTheBackupCopy() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(rootDirectory: root)
    let kept = UUID(), secret = UUID()
    store.upsert(MeetingRecord(id: kept, title: "Standup", status: .completed, transcriptText: "ordinary"))
    store.upsert(MeetingRecord(id: secret, title: "Board review", status: .completed,
                               transcriptText: "the confidential-kestrel figures"))
    store.delete(id: secret)
    let backup = root.appendingPathComponent("meetings.backup.json")
    try #require(String(decoding: try Data(contentsOf: backup), as: UTF8.self).contains("confidential-kestrel"),
                 "fixture: the delete's save left the meeting in the backup copy")

    let outcome = try #require(store.forgetIndexHistory(), "\(store.storageErrorMessage ?? "")")

    let backupText = String(decoding: try Data(contentsOf: backup), as: UTF8.self)
    #expect(!backupText.contains("confidential-kestrel"), "the deleted meeting's text is still in meetings.backup.json")
    #expect(outcome.backupRefreshed)
    #expect(!ForgetHistoryNotice.result(outcome).contains("backup copy could not"), "\(ForgetHistoryNotice.result(outcome))")
    // Nothing of the history is left, including the generation the refresh itself kept.
    let history = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("meetings.history").path)) ?? []
    #expect(!history.contains { $0.hasPrefix("g-") }, "\(history)")
    // The live pair still loads, with the meeting that was kept.
    let reopened = MeetingStore(rootDirectory: root)
    #expect(!reopened.isDegraded, "\(reopened.health)")
    #expect(reopened.meetings.map(\.id) == [kept])
}

@MainActor
@Test("When the backup copy cannot be refreshed, Forget History still forgets the history and says what is left (F580)")
func forgetHistorySaysWhenTheBackupCopyWasNotRefreshed() throws {
    let root = try makeRoot()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }
    let store = MeetingStore(rootDirectory: root)
    for title in ["Standup", "Planning"] {
        store.upsert(MeetingRecord(id: UUID(), title: title, status: .completed))
    }
    // The library folder cannot be written, so the refreshing save fails; the history folder inside
    // it can still be emptied.
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)

    let outcome = try #require(store.forgetIndexHistory(), "\(store.storageErrorMessage ?? "")")

    #expect(!outcome.backupRefreshed)
    #expect(outcome.removedGenerations > 0, "the history was not forgotten")
    let result = ForgetHistoryNotice.result(outcome)
    #expect(result.contains("backup copy could not be refreshed"), "\(result)")
}

@MainActor
@Test("Forget History's dialog no longer says the backup copy stays until the next save (F580)")
func theDialogSaysTheBackupCopyIsRefreshed() {
    let inventory = MeetingStore.ForgetHistoryInventory(conflictCopies: 0, quarantineCopies: [], preRestoreSnapshots: [])
    let message = ForgetHistoryNotice.dialogMessage(inventory)
    #expect(!message.contains("stays until your next save"), "\(message)")
    #expect(message.contains("backup copy"), "\(message)")
}
