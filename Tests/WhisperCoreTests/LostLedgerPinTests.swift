import Foundation
import Testing
@testable import WhisperCore

// F677 — the high-water pin survives a lost, unreadable or set-aside ledger.
//
// Retention rule 3 reads a generation's record count only from the ledger: `StoreHistory.entries()`
// reports nil for every file. So whenever the ledger stopped describing the generations on disk —
// deleted by hand (RECOVERY.md's documented exit), unreadable, set aside by a backup restore (F463),
// or a history folder moved aside for two saves and then put back (F648's round-2 review) — every
// generation already there lost its count, the pin moved to whatever the next save wrote, and the
// largest library on disk was pruned by the ordinary rules. The counts are in the files themselves;
// a save now reads each undescribed generation once and records it.

private struct Note: Codable, Equatable { let title: String }

private struct Fixture {
    let directory: URL
    var primaryURL: URL { directory.appendingPathComponent("meetings.json") }
    var backupURL: URL { directory.appendingPathComponent("meetings.backup.json") }
    var ledgerURL: URL { directory.appendingPathComponent("meetings.ledger.json") }
    var historyURL: URL { directory.appendingPathComponent("meetings.history", isDirectory: true) }
}

private func makeFixture() throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LostLedgerPin-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return Fixture(directory: directory)
}

/// Counts the history entries a save reads, so the "once" claim is measured rather than asserted.
private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    func add() { lock.lock(); reads += 1; lock.unlock() }
    func take() -> Int { lock.lock(); defer { reads = 0; lock.unlock() }; return reads }
}

private func makeStore(_ fixture: Fixture, counting counter: ReadCounter? = nil) -> BackupJSONStore<[Note]> {
    var io = StoreFileIO.live
    io.read = { url, phase in
        if phase == .readHistoryEntry { counter?.add() }
        return try StoreFileIO.live.read(url, phase)
    }
    return BackupJSONStore<[Note]>(
        primaryURL: fixture.primaryURL, backupURL: fixture.backupURL, io: io,
        writer: "aaaa0677", recordCount: { $0.count }
    )
}

/// The record counts of every generation FILE on disk, decoded from its bytes — never the ledger.
private func countsOnDisk(_ fixture: Fixture) -> [Int] {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: fixture.historyURL.path)) ?? [])
        .filter { $0.hasPrefix("g-") }
    return names.compactMap { name in
        guard let data = try? Data(contentsOf: fixture.historyURL.appendingPathComponent(name)),
              let notes = try? JSONDecoder().decode([Note].self, from: data) else { return nil }
        return notes.count
    }.sorted()
}

/// Seventeen meetings, a wipe, then a few ordinary saves — every save at one instant, so no age
/// anchor holds anything and the pin alone keeps the seventeen.
private func wipeThenKeepWorking(_ store: BackupJSONStore<[Note]>, now: Int) throws -> GenerationToken {
    var token = try store.save((0..<17).map { Note(title: "meeting \($0)") }, now: now).token
    token = try store.save([], expecting: token, now: now).token
    for index in 0..<5 {
        token = try store.save([Note(title: "after the wipe \(index)")], expecting: token, now: now).token
    }
    return token
}

private let now = 1_757_000_000

@Test("With the ledger deleted, the pinned generation on disk survives the saves that follow (F677)")
func aDeletedLedgerKeepsThePin() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = makeStore(fixture)
    _ = try wipeThenKeepWorking(store, now: now)
    try #require(countsOnDisk(fixture).contains(17), "precondition: the pin holds the seventeen")

    // RECOVERY.md's documented exit, and what a restore of a ledger-less backup does (F463).
    try FileManager.default.removeItem(at: fixture.ledgerURL)
    var token = try #require(try store.load()?.token)
    for index in 0..<5 {
        token = try store.save([Note(title: "after the ledger went \(index)")], expecting: token, now: now).token
    }

    #expect(countsOnDisk(fixture).contains(17), "the pinned generation was pruned: \(countsOnDisk(fixture))")
    // And the recovery list can say how many meetings it holds again.
    #expect(try store.retainedGenerations().contains { $0.recordCount == 17 })
}

@Test("An unreadable ledger does not cost the pin the generation it was keeping (F677)")
func anUnreadableLedgerKeepsThePin() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = makeStore(fixture)
    _ = try wipeThenKeepWorking(store, now: now)
    try #require(countsOnDisk(fixture).contains(17))

    try Data("{ torn".utf8).write(to: fixture.ledgerURL)
    var token = try #require(try store.load()?.token)
    for index in 0..<5 {
        token = try store.save([Note(title: "after the ledger tore \(index)")], expecting: token, now: now).token
    }

    #expect(countsOnDisk(fixture).contains(17), "the pinned generation was pruned: \(countsOnDisk(fixture))")
}

/// F648's round-2 review, probe P1: the first save without the folder recreates it, the second
/// lists the new folder and drops the records for files that are not in it — correctly, for what it
/// could see — and when the old folder comes back its generations have no records.
@Test("A history folder moved aside for two saves and put back keeps the pin (F677)")
func aHistoryFolderPutBackKeepsThePin() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = makeStore(fixture)
    var token = try store.save((0..<17).map { Note(title: "meeting \($0)") }, now: now).token
    token = try store.save([], expecting: token, now: now).token
    // Past the ledger's 64-record window, so only "its file is on disk" keeps the pin's record.
    for index in 0..<70 {
        token = try store.save([Note(title: "after the wipe \(index)")], expecting: token, now: now).token
    }
    try #require(countsOnDisk(fixture).contains(17))

    let aside = fixture.directory.appendingPathComponent("meetings.history.aside")
    try FileManager.default.moveItem(at: fixture.historyURL, to: aside)
    token = try store.save([Note(title: "while away 1")], expecting: token, now: now).token
    token = try store.save([Note(title: "while away 2")], expecting: token, now: now).token
    try FileManager.default.removeItem(at: fixture.historyURL)
    try FileManager.default.moveItem(at: aside, to: fixture.historyURL)
    for index in 0..<5 {
        token = try store.save([Note(title: "folder is back \(index)")], expecting: token, now: now).token
    }

    #expect(countsOnDisk(fixture).contains(17), "the pinned generation was pruned: \(countsOnDisk(fixture))")
}

/// The cost, pinned: reading a generation is a full read and parse of an index on the main actor, so
/// it must happen once per generation and not once per save.
@Test("Each generation the ledger lost is read once, by the first save, and recorded (F677)")
func eachUndescribedGenerationIsReadOnce() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let counter = ReadCounter()
    _ = try wipeThenKeepWorking(makeStore(fixture), now: now)
    try FileManager.default.removeItem(at: fixture.ledgerURL)
    let onDisk = try FileManager.default.contentsOfDirectory(atPath: fixture.historyURL.path)
        .filter { $0.hasPrefix("g-") }.count

    // A launch after the ledger went: this process wrote none of those generations, so nothing it
    // remembers can answer for them.
    let launched = makeStore(fixture, counting: counter)
    var token = try #require(try launched.load()?.token)
    token = try launched.save([Note(title: "first save without a ledger")], expecting: token, now: now).token
    let firstSave = counter.take()
    #expect(firstSave > 0 && firstSave <= onDisk, "the first save read \(firstSave) of \(onDisk) generations")

    // And the launch after that: memory is empty again, so only the ledger can answer.
    let relaunched = makeStore(fixture, counting: counter)
    for index in 0..<3 {
        token = try relaunched.save([Note(title: "later \(index)")], expecting: token, now: now).token
    }
    #expect(counter.take() == 0, "later saves read generations the ledger now describes")
}

/// Two copies of one content (A, B, A) share one record, which names the newer file; the older
/// copy's count is the same, so it is taken from that record rather than read.
@Test("A copy whose bytes another record describes is counted without reading it (F677)")
func anEqualContentCopyIsCountedWithoutARead() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let counter = ReadCounter()
    let store = makeStore(fixture)
    let full = (0..<4).map { Note(title: "meeting \($0)") }
    var token = try store.save(full, now: now).token
    token = try store.save(Array(full.dropFirst()), expecting: token, now: now).token
    token = try store.save(full, expecting: token, now: now).token

    // A relaunch, so the count can only come from the ledger's record of the twin, not from memory.
    let relaunched = makeStore(fixture, counting: counter)
    token = try relaunched.save([Note(title: "next")], expecting: token, now: now).token

    #expect(counter.take() == 0, "a copy with a recorded twin was read to learn what its twin says")
    let ledger = try #require(StoreLedger.read(at: fixture.ledgerURL))
    #expect(ledger.history.filter { $0.recordCount == 4 }.count == 2, "the older copy was not recorded")
}

/// A ledger from a newer build is left exactly as it is (F190), so this build cannot record what it
/// learned there; it must still not re-read every generation at every save.
@Test("With a ledger this build may not overwrite, each generation is still read once per launch (F677)")
func aNewerLedgerDoesNotMakeEverySaveReadTheHistory() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let counter = ReadCounter()
    _ = try wipeThenKeepWorking(makeStore(fixture), now: now)
    try Data(#"{"formatVersion": 99}"#.utf8).write(to: fixture.ledgerURL)

    // A launch with that ledger in place: nothing this process remembers describes the history.
    let store = makeStore(fixture, counting: counter)
    var token = try #require(try store.load()?.token)
    token = try store.save([Note(title: "one")], expecting: token, now: now).token
    #expect(counter.take() > 0, "precondition: the first save had to read the history")
    for index in 0..<3 {
        token = try store.save([Note(title: "more \(index)")], expecting: token, now: now).token
    }

    #expect(counter.take() == 0, "every save re-read generations it had already counted")
    #expect(try String(contentsOf: fixture.ledgerURL, encoding: .utf8).contains("99"), "the newer ledger was overwritten")
    #expect(countsOnDisk(fixture).contains(17), "the pinned generation was pruned: \(countsOnDisk(fixture))")
}
