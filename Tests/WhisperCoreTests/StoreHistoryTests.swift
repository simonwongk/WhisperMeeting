import Foundation
import Testing
@testable import WhisperCore

// F190 Task 5 — retained generations as physically independent copies.
//
// Two rules carry this file, and both were learned the hard way.
//
// NEVER link(2). A hard link makes the retained generation an ALIAS of the live file, so
// `cp good.json meetings.json`, a shell redirect, `rsync --inplace` or any non-atomic
// `Data.write(to:)` rewrites the archive through the live name — the archive is destroyed by the
// very operation it exists to survive. `link` also bumps the source's `st_ctime`, which is in
// F211's identity tuple, silently voiding the decode-skip on every later save. This was the
// most-cited fatal flaw in the rejected designs, so it gets the first test.
//
// RETENTION IS NEVER COUNTED IN SAVES. `AppModel.performStartupRecovery` calls `upsert` once per
// orphan folder and `upsert` persists, so the 2026-08-14 loop wrote TEN generations inside one
// launch. A "keep the newest 5" window would have been emptied before the user ever saw it —
// destroying history in exactly the incident shape this ticket exists for.
//
// Genuinely red without the fix: `StoreHistory` does not exist.

private struct Note: Codable, Equatable { let title: String }

private func makeHistoryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StoreHistoryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Stages `payload`, records it as `generation`, then INSTALLS it by renaming staging onto
/// `installAt` — the real protocol's order (stage → retain → install), which matters enormously.
///
/// `install` is a rename, so the staged file's inode BECOMES the live primary's. A retention step
/// implemented with `link(2)` would therefore alias the live file, and an in-place rewrite of the
/// primary would reach through and destroy the archive. A helper that merely deleted the staging
/// file instead of renaming it could never exhibit that — the first draft of this file did exactly
/// that and the hardlink mutation passed, which is the whole reason the rename is spelled out here.
@discardableResult
private func record(
    _ payload: Data,
    as generation: UInt64,
    into history: StoreHistory,
    directory: URL,
    installAt primaryURL: URL? = nil
) throws -> String? {
    let staged = directory.appendingPathComponent("staging-\(generation).json")
    try payload.write(to: staged, options: .atomic)
    let name = try history.record(
        stagedAt: staged, generation: generation, fingerprint: StoreFingerprint.of(payload)
    )
    if let primaryURL {
        try StoreFileIO.live.rename(staged, primaryURL, .install)
    } else {
        try? FileManager.default.removeItem(at: staged)
    }
    return name
}

@Test("A retained generation survives an in-place overwrite of the live index (F190)")
func retainedGenerationIsIndependentOfTheLiveFile() throws {
    let directory = try makeHistoryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let primaryURL = directory.appendingPathComponent("meetings.json")
    let history = StoreHistory(primaryURL: primaryURL)

    let original = try JSONEncoder().encode([Note(title: "Seventeen real meetings")])
    let name = try #require(
        try record(original, as: 1, into: history, directory: directory, installAt: primaryURL)
    )
    #expect(try Data(contentsOf: primaryURL) == original)

    // The hazard, exactly: a NON-atomic, in-place rewrite of the live name. With link(2) this would
    // reach through and rewrite the archive too. `cp` and shell redirects behave the same way, and
    // RECOVERY.md tells users to use `cp`.
    let handle = try FileHandle(forWritingTo: primaryURL)
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: Data("[]".utf8))
    try handle.close()
    #expect(try Data(contentsOf: primaryURL) == Data("[]".utf8))

    let retained = try #require(history.retained().first)
    #expect(retained.name == name)
    #expect(retained.bytesMatchName, "the retained bytes were rewritten through the live name")
    #expect(try JSONDecoder().decode([Note].self, from: try history.data(of: retained))
            == [Note(title: "Seventeen real meetings")])
}

@Test("A retained generation has its own inode, so neither name can affect the other (F190)")
func retainedGenerationHasADistinctInode() throws {
    let directory = try makeHistoryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let primaryURL = directory.appendingPathComponent("meetings.json")
    let history = StoreHistory(primaryURL: primaryURL)
    let payload = Data("[{\"title\":\"x\"}]".utf8)
    let name = try #require(
        try record(payload, as: 1, into: history, directory: directory, installAt: primaryURL)
    )

    let liveIdentity = try #require(StoreFileIdentity(path: primaryURL.path))
    let archived = try #require(
        StoreFileIdentity(path: history.directoryURL.appendingPathComponent(name).path)
    )
    #expect(archived.inode != liveIdentity.inode, "the archive is an alias of the live file")
}

@Test("Ten stub saves in one launch cannot evict the last real generation (F190)")
func aBurstOfStubSavesCannotEvictTheHighWaterGeneration() throws {
    let directory = try makeHistoryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let primaryURL = directory.appendingPathComponent("meetings.json")
    let history = StoreHistory(primaryURL: primaryURL)

    // The incident shape. Generation 1 holds seventeen meetings; then startup recovery writes ten
    // generations of blank stubs in one launch, all with recordCount 0.
    let real = try JSONEncoder().encode((0..<17).map { Note(title: "meeting \($0)") })
    let realName = try #require(try record(real, as: 1, into: history, directory: directory))
    var counts: [String: Int] = [realName: 17]
    for generation in UInt64(2)...11 {
        let stub = Data("[]".utf8)
        let name = try #require(
            try record(stub, as: generation, into: history, directory: directory)
        )
        counts[name] = 0
    }

    // A budget tight enough that pruning REALLY happens. With the 256 MB default nothing is ever
    // evicted at this payload size, so the test passed even with the high-water pin deleted — it
    // proved the budget was generous, not that the pin worked.
    let removed = history.prune(
        policy: RetentionPolicy(recentCount: 3, ageAnchors: [], byteBudget: 1),
        now: 1_757_000_000,
        recordCounts: counts,
        writtenAt: [:],
        liveFingerprints: []
    )
    #expect(removed.count >= 7, "nothing was pruned, so no retention rule was under test")
    #expect(!removed.contains(realName), "the seventeen-meeting generation was pruned by a save burst")
    #expect(history.retained().contains { $0.name == realName })
    #expect(try JSONDecoder().decode([Note].self, from:
        try history.data(of: try #require(history.retained().first { $0.name == realName }))).count == 17)
}

@Test("Retention keeps the newest generation older than each age anchor (F190)")
func retentionKeepsAnAnchorPerAge() throws {
    let directory = try makeHistoryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let primaryURL = directory.appendingPathComponent("meetings.json")
    let history = StoreHistory(primaryURL: primaryURL)

    let now = 1_757_000_000
    // One generation per hour for two weeks. Without anchors, only the newest few survive and a
    // user who notices a problem a week later has nothing to go back to.
    var writtenAt: [String: Int] = [:]
    for hour in 0..<336 {
        let payload = Data("[{\"h\":\(hour)}]".utf8)
        let name = try #require(
            try record(payload, as: UInt64(hour + 1), into: history, directory: directory)
        )
        writtenAt[name] = now - (336 - hour) * 3_600
    }

    let policy = RetentionPolicy()
    let pruned = Set(history.prune(
        policy: policy, now: now, recordCounts: [:], writtenAt: writtenAt, liveFingerprints: []
    ))
    let survivors = history.retained().filter { !pruned.contains($0.name) }

    #expect(survivors.count >= policy.recentCount + policy.ageAnchors.count)
    for anchor in policy.ageAnchors {
        #expect(
            survivors.contains { (writtenAt[$0.name] ?? now) <= now - anchor },
            "nothing survived older than \(anchor)s, so there is no anchor for that age"
        )
    }
}

@Test("The live primary's bytes are never pruned, whatever the budget says (F190)")
func retentionNeverPrunesTheLiveBytes() throws {
    let directory = try makeHistoryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let primaryURL = directory.appendingPathComponent("meetings.json")
    let history = StoreHistory(primaryURL: primaryURL)

    let live = Data("[{\"title\":\"live\"}]".utf8)
    let liveName = try #require(try record(live, as: 1, into: history, directory: directory))
    for generation in UInt64(2)...6 {
        try record(Data("[{\"g\":\(generation)}]".utf8), as: generation,
                   into: history, directory: directory)
    }

    // A byte budget of zero: everything the rules do not explicitly keep must go.
    let pruned = history.prune(
        policy: RetentionPolicy(recentCount: 1, ageAnchors: [], byteBudget: 0),
        now: 1_757_000_000,
        recordCounts: [:],
        writtenAt: [:],
        liveFingerprints: [StoreFingerprint.of(live)]
    )
    #expect(!pruned.contains(liveName), "pruned the bytes that are currently live")
}

@Test("A conflict branch is never pruned automatically (F190)")
func conflictBranchesAreNeverPrunedAutomatically() throws {
    let directory = try makeHistoryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let primaryURL = directory.appendingPathComponent("meetings.json")
    let history = StoreHistory(primaryURL: primaryURL)
    try FileManager.default.createDirectory(at: history.directoryURL, withIntermediateDirectories: true)

    // A conflict branch is a losing writer's work. It exists nowhere else, so no automatic policy
    // may delete it — only the user, having seen it.
    let conflict = history.directoryURL.appendingPathComponent("conflict-0001-abcdef0123456789.json")
    try Data("[{\"title\":\"the other writer's work\"}]".utf8).write(to: conflict, options: .atomic)
    for generation in UInt64(1)...6 {
        try record(Data("[{\"g\":\(generation)}]".utf8), as: generation,
                   into: history, directory: directory)
    }

    let pruned = history.prune(
        policy: RetentionPolicy(recentCount: 1, ageAnchors: [], byteBudget: 0),
        now: 1_757_000_000, recordCounts: [:], writtenAt: [:], liveFingerprints: []
    )
    #expect(!pruned.contains(conflict.lastPathComponent))
    #expect(FileManager.default.fileExists(atPath: conflict.path))
    #expect(history.conflictBranchCount() == 1)
}

@Test("A retained file whose bytes no longer match its name is reported, not hidden (F190)")
func aTamperedRetainedFileIsReportedRatherThanServed() throws {
    let directory = try makeHistoryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let primaryURL = directory.appendingPathComponent("meetings.json")
    let history = StoreHistory(primaryURL: primaryURL)
    let payload = Data("[{\"title\":\"original\"}]".utf8)
    let name = try #require(try record(payload, as: 1, into: history, directory: directory))

    // Rewrite the archived file in place, so its bytes no longer fingerprint to its own name.
    try Data("[{\"title\":\"substituted\"}]".utf8)
        .write(to: history.directoryURL.appendingPathComponent(name))

    // Never silently omitted (the user would think the generation vanished) and never silently
    // served (they would restore bytes that are not the ones they chose).
    let entry = try #require(history.retained().first { $0.name == name })
    #expect(!entry.bytesMatchName)
    #expect(entry.recordCount == nil)
    #expect(throws: StoreHistoryError.fingerprintMismatch(name)) { _ = try history.data(of: entry) }
}

@Test("History names are content-addressed, so a generation identifies itself (F190)")
func historyNamesCarryTheirOwnFingerprint() throws {
    let directory = try makeHistoryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let primaryURL = directory.appendingPathComponent("meetings.json")
    let history = StoreHistory(primaryURL: primaryURL)
    let payload = Data("[{\"title\":\"x\"}]".utf8)
    let name = try #require(try record(payload, as: 7, into: history, directory: directory))

    // This is what makes a lagged or lost ledger update harmless: the directory scan alone recovers
    // the sequence and the fingerprint, with no ledger record needed.
    #expect(name == "g-000000007-\(StoreFingerprint.of(payload)).json")
    let entry = try #require(history.retained().first)
    #expect(entry.sequence == 7)
    #expect(entry.fingerprint == StoreFingerprint.of(payload))
    #expect(entry.byteCount == payload.count)
}
