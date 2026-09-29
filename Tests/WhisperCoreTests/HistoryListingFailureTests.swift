import Foundation
import Testing
@testable import WhisperCore

// F648 — a save that cannot list `<stem>.history` must not decide which ledger records to drop.
//
// F517 keeps a ledger record past the newest 64 for exactly as long as its generation's file is on
// disk, and it learns what is on disk from one listing per save. That listing used to be
// `(try? …) ?? []`, so a listing that FAILED read as an empty folder: the save dropped every record
// past 64, the high-water pin lost its record count, and the next save that could see the folder
// pruned the generation the pin existed for. Missing information is not evidence of absence
// (AGENTS.md: "the fallback must be a deferred action and never a destructive one").

private struct Note: Codable, Equatable { let title: String }

private final class ListingSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = false
    var isFailing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return failing }
        set { lock.lock(); failing = newValue; lock.unlock() }
    }
}

private struct Fixture {
    let directory: URL
    var primaryURL: URL { directory.appendingPathComponent("meetings.json") }
    var backupURL: URL { directory.appendingPathComponent("meetings.backup.json") }
    var historyURL: URL { directory.appendingPathComponent("meetings.history", isDirectory: true) }
}

private func makeFixture() throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("HistoryListingFailure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return Fixture(directory: directory)
}

/// The record counts of every generation FILE on disk, decoded from its bytes — never the ledger,
/// which is the thing under test.
private func countsOnDisk(_ fixture: Fixture) -> [Int] {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: fixture.historyURL.path)) ?? [])
        .filter { $0.hasPrefix("g-") }
    return names.compactMap { name in
        guard let data = try? Data(contentsOf: fixture.historyURL.appendingPathComponent(name)),
              let notes = try? JSONDecoder().decode([Note].self, from: data) else { return nil }
        return notes.count
    }.sorted()
}

/// Seventeen meetings, a wipe, then a hundred ordinary saves — F517's shape, so the pinned
/// generation's record is far past the newest 64 and held only by "its file is on disk".
private func wipeThenKeepWorking(_ store: BackupJSONStore<[Note]>, now: Int) throws -> GenerationToken {
    var token = try store.save((0..<17).map { Note(title: "meeting \($0)") }, now: now).token
    token = try store.save([], expecting: token, now: now).token
    for index in 0..<100 {
        token = try store.save([Note(title: "after the wipe \(index)")], expecting: token, now: now).token
    }
    return token
}

@Test("One failed history listing does not cost the high-water pin its record (F648)")
func aFailedListingKeepsThePinnedRecord() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let listing = ListingSwitch()
    var io = StoreFileIO.live
    io.contentsOfDirectory = { url, phase in
        if listing.isFailing, phase == .listHistory { throw CocoaError(.fileReadUnknown) }
        return try StoreFileIO.live.contentsOfDirectory(url, phase)
    }
    let store = BackupJSONStore<[Note]>(
        primaryURL: fixture.primaryURL, backupURL: fixture.backupURL, io: io,
        writer: "aaaa0648", recordCount: { $0.count }
    )
    let now = 1_757_000_000
    var token = try wipeThenKeepWorking(store, now: now)
    try #require(countsOnDisk(fixture).contains(17), "precondition: F517 holds the pin past 64 saves")

    listing.isFailing = true
    token = try store.save([Note(title: "the listing fails once")], expecting: token, now: now).token
    listing.isFailing = false
    _ = try store.save([Note(title: "the listing works again")], expecting: token, now: now)

    #expect(countsOnDisk(fixture).contains(17), "the pinned generation was pruned: \(countsOnDisk(fixture))")
}

@Test("A history folder squatted for one save and put back keeps the pin (F648)")
func aSquattedThenRestoredHistoryKeepsThePin() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = BackupJSONStore<[Note]>(
        primaryURL: fixture.primaryURL, backupURL: fixture.backupURL,
        writer: "aaaa0648", recordCount: { $0.count }
    )
    let now = 1_757_000_000
    var token = try wipeThenKeepWorking(store, now: now)
    try #require(countsOnDisk(fixture).contains(17))

    // What F553's reproduction does to a library: the folder moved aside and a file in its place,
    // for one save, then put back.
    let aside = fixture.directory.appendingPathComponent("meetings.history.aside")
    try FileManager.default.moveItem(at: fixture.historyURL, to: aside)
    try Data("not a directory".utf8).write(to: fixture.historyURL)
    token = try store.save([Note(title: "while squatted")], expecting: token, now: now).token
    try FileManager.default.removeItem(at: fixture.historyURL)
    try FileManager.default.moveItem(at: aside, to: fixture.historyURL)
    _ = try store.save([Note(title: "folder is back")], expecting: token, now: now)

    #expect(countsOnDisk(fixture).contains(17), "the pinned generation was pruned: \(countsOnDisk(fixture))")
}

@Test("Once the listing works again, records for files that are gone are dropped as before (F648)")
func aRecoveredListingTrimsTheLedgerAgain() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let listing = ListingSwitch()
    var io = StoreFileIO.live
    io.contentsOfDirectory = { url, phase in
        if listing.isFailing, phase == .listHistory { throw CocoaError(.fileReadUnknown) }
        return try StoreFileIO.live.contentsOfDirectory(url, phase)
    }
    let store = BackupJSONStore<[Note]>(
        primaryURL: fixture.primaryURL, backupURL: fixture.backupURL, io: io,
        writer: "aaaa0648", recordCount: { $0.count }
    )
    let now = 1_757_000_000
    var token = try wipeThenKeepWorking(store, now: now)

    // Ten saves that cannot see the folder: records are kept rather than decided about...
    listing.isFailing = true
    for index in 0..<10 {
        token = try store.save([Note(title: "blind \(index)")], expecting: token, now: now).token
    }
    listing.isFailing = false
    // ...and the first save that can see it again trims back to F517's bound.
    _ = try store.save([Note(title: "sighted")], expecting: token, now: now)

    let ledger = try #require(StoreLedger.read(at: fixture.directory.appendingPathComponent("meetings.ledger.json")))
    let onDisk = Set(
        try FileManager.default.contentsOfDirectory(atPath: fixture.historyURL.path).filter { $0.hasPrefix("g-") }
    )
    #expect(ledger.history.count <= 64 + onDisk.count, "ledger kept \(ledger.history.count) records")
    #expect(countsOnDisk(fixture).contains(17))
}

@Test("A long outage keeps the ledger bounded, and the pin survives it (F648)")
func aLongOutageKeepsTheLedgerBounded() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = BackupJSONStore<[Note]>(
        primaryURL: fixture.primaryURL, backupURL: fixture.backupURL,
        writer: "aaaa0648", recordCount: { $0.count }
    )
    let now = 1_757_000_000
    var token = try wipeThenKeepWorking(store, now: now)
    let aside = fixture.directory.appendingPathComponent("meetings.history.aside")
    try FileManager.default.moveItem(at: fixture.historyURL, to: aside)
    try Data("not a directory".utf8).write(to: fixture.historyURL)
    let filesAside = try FileManager.default.contentsOfDirectory(atPath: aside.path)
        .filter { $0.hasPrefix("g-") }.count

    // Two hundred saves that can neither list nor retain. Deferring must not become a log of
    // every save: the only records it adds past the window are the at most 64 that were inside
    // the window when the outage began (the saves during it retain nothing, so name nothing).
    for index in 0..<200 {
        token = try store.save([Note(title: "outage \(index)")], expecting: token, now: now).token
    }
    let ledgerURL = fixture.directory.appendingPathComponent("meetings.ledger.json")
    let during = try #require(StoreLedger.read(at: ledgerURL))
    #expect(during.history.count <= 64 + 64 + filesAside, "ledger grew to \(during.history.count) records")

    try FileManager.default.removeItem(at: fixture.historyURL)
    try FileManager.default.moveItem(at: aside, to: fixture.historyURL)
    _ = try store.save([Note(title: "folder is back")], expecting: token, now: now)
    #expect(countsOnDisk(fixture).contains(17), "the pinned generation was pruned: \(countsOnDisk(fixture))")
    let after = try #require(StoreLedger.read(at: ledgerURL))
    let onDisk = try FileManager.default.contentsOfDirectory(atPath: fixture.historyURL.path)
        .filter { $0.hasPrefix("g-") }.count
    #expect(after.history.count <= 64 + onDisk, "the ledger did not trim back: \(after.history.count) records")
}
