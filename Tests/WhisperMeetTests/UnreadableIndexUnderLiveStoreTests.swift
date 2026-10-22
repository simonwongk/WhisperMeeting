import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F1036 — what a meeting save does when another copy has left both index files unreadable beside a live
// store. Found by reading `BackupJSONStore.save` and pinned here: its F187 quarantine step copies each
// undecodable file aside before anything replaces it, and the compare-and-swap lets an undecodable
// primary go (rule 3), so the save goes through and the library stays writable. What it did not do was
// say so: `SaveOutcome.quarantined` was dropped, so the copies were set aside without a word, unlike the
// load's identical finding, which is said.

@MainActor
@Test("A save over two unreadable index files copies both aside, saves the list, and says so (F1036)")
func aSaveOverUnreadableIndexFilesKeepsThemAndSays() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F1036-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(rootDirectory: root)
    let id = UUID()
    store.upsert(MeetingRecord(id: id, title: "Weekly sync", status: .completed, transcriptText: "Hi."))
    store.upsert(MeetingRecord(id: UUID(), title: "Planning", status: .completed, transcriptText: "Hi."))
    let primary = root.appendingPathComponent("meetings.json")
    let backup = root.appendingPathComponent("meetings.backup.json")
    try #require(FileManager.default.fileExists(atPath: backup.path), "the second save left no backup to spoil")

    // Another copy leaves both files unreadable.
    let junk = Data("not an index".utf8)
    try junk.write(to: primary)
    try junk.write(to: backup)
    store.update(id: id) { $0.title = "Q3 budget review" }

    // The save went through, and the library is still writable.
    #expect(!store.isDegraded)
    #expect(MeetingStore(rootDirectory: root).meeting(id: id)?.title == "Q3 budget review")
    // Both unreadable files were copied aside, byte for byte.
    let aside = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.contains(".unreadable-") }.sorted()
    #expect(aside.count == 2, "\(aside)")
    for name in aside { #expect(try Data(contentsOf: root.appendingPathComponent(name)) == junk, "\(name)") }
    // And the user is told, by name, as the load says it.
    let message = store.storageErrorMessage ?? "nil"
    for name in aside { #expect(message.contains(name), "\(message)") }
    #expect(message.contains("meetings.json"), "\(message)")
}

@MainActor
@Test("An ordinary save says nothing about copies set aside (F1036 control)")
func anOrdinarySaveSaysNothingSetAside() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F1036-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(rootDirectory: root)
    let id = UUID()
    store.upsert(MeetingRecord(id: id, title: "Weekly sync", status: .completed, transcriptText: "Hi."))
    store.update(id: id) { $0.title = "Q3 budget review" }

    #expect(store.storageErrorMessage == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.contains(".unreadable-") }.isEmpty)
}
