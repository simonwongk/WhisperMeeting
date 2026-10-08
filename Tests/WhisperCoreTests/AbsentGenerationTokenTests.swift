import Foundation
import Testing
@testable import WhisperCore

// F864 — the token for "I looked and there was no file". Before it, a store that loaded a library
// with no primary held no token, and its first save was unchecked: last-writer-wins over another
// writer's first save. The behavioural RED is `firstIndexSaveOfAFreshLibraryIsChecked` in
// WhisperMeetTests; these pin the store rule itself, including the cases where every adoption rule
// would otherwise let the save through.

private struct Entry: Codable, Equatable { let title: String }

private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AbsentToken-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func store(_ directory: URL, writer: String) -> BackupJSONStore<[Entry]> {
    BackupJSONStore<[Entry]>(
        primaryURL: directory.appendingPathComponent("meetings.json"),
        backupURL: directory.appendingPathComponent("meetings.backup.json"),
        writer: writer,
        recordCount: { $0.count }
    )
}

@Test("Expecting no file, a save over no file installs with no parent (F864)")
func expectingNoFileOverNoFileInstalls() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = store(directory, writer: "aaaa0001")
    #expect(try first.load() == nil)

    let outcome = try first.save([Entry(title: "first")], expecting: .absent)

    #expect(outcome.parent == nil)
    #expect(outcome.phases.contains(.install))
    #expect(try first.load()?.value == [Entry(title: "first")])
}

@Test("Expecting no file, finding another writer's first save is a conflict, and the loser is kept (F864)")
func expectingNoFileLosesToAnotherWritersFirstSave() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let winner = store(directory, writer: "aaaa0001")
    let loser = store(directory, writer: "bbbb0002")
    #expect(try winner.load() == nil)
    #expect(try loser.load() == nil)

    _ = try winner.save([Entry(title: "the other copy's meeting")], expecting: .absent)

    var preservedAs: String?
    do {
        _ = try loser.save([Entry(title: "this copy's meeting")], expecting: .absent)
        Issue.record("the save replaced another writer's first save")
    } catch let error as BackupJSONStoreError {
        guard case let .generationConflict(_, expected, _, preserved) = error else {
            Issue.record("expected .generationConflict, got \(error)")
            return
        }
        #expect(expected == .absent)
        preservedAs = preserved
    }
    #expect(try winner.load()?.value == [Entry(title: "the other copy's meeting")])
    let name = try #require(preservedAs)
    let branch = try Data(contentsOf: directory.appendingPathComponent("meetings.history").appendingPathComponent(name))
    #expect(try JSONDecoder().decode([Entry].self, from: branch) == [Entry(title: "this copy's meeting")])
}

@Test("Expecting no file, a file with no ledger is still a conflict, not adopted (F864)")
func expectingNoFileDoesNotAdoptALedgerlessFile() throws {
    // A token holder adopts a primary with no ledger (a pre-F190 library, an old bundle's write) as
    // descending from what it read. A writer that read NOTHING cannot have read that file's parent.
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let loser = store(directory, writer: "bbbb0002")
    #expect(try loser.load() == nil)
    let foreign = try JSONEncoder().encode([Entry(title: "written by an old bundle")])
    try foreign.write(to: directory.appendingPathComponent("meetings.json"))

    #expect(throws: BackupJSONStoreError.self) {
        try loser.save([Entry(title: "this copy's meeting")], expecting: .absent)
    }
    #expect(try Data(contentsOf: directory.appendingPathComponent("meetings.json")) == foreign)
}

@Test("Expecting no file, an undecodable file that appeared is quarantined, as with any token (F864)")
func expectingNoFileQuarantinesAnUndecodableFile() throws {
    // Rule 3 is unchanged: bytes that do not decode are the F187 ladder, not a race. They are copied
    // aside before anything replaces them.
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = store(directory, writer: "bbbb0002")
    #expect(try writer.load() == nil)
    try Data("not json".utf8).write(to: directory.appendingPathComponent("meetings.json"))

    let outcome = try writer.save([Entry(title: "this copy's meeting")], expecting: .absent)

    #expect(!outcome.quarantined.isEmpty)
    #expect(try writer.load()?.value == [Entry(title: "this copy's meeting")])
}

@Test("The absent token matches no bytes, even empty ones (F864)")
func theAbsentTokenMatchesNoBytes() {
    #expect(!GenerationToken.absent.matches(fingerprint: StoreFingerprint.of(Data()), byteCount: 0))
    #expect(GenerationToken.absent.expectsNoFile)
    let real = GenerationToken(sequence: 0, fingerprint: StoreFingerprint.of(Data()), byteCount: 0,
                               writer: "aaaa0001", verified: false)
    #expect(!real.expectsNoFile)
}
