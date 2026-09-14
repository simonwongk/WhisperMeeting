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
    var nameOfHour: [Int: String] = [:]
    for hour in 0..<336 {
        let payload = Data("[{\"h\":\(hour)}]".utf8)
        let name = try #require(
            try record(payload, as: UInt64(hour + 1), into: history, directory: directory)
        )
        nameOfHour[hour] = name
        writtenAt[name] = now - (336 - hour) * 3_600
    }

    let policy = RetentionPolicy()
    let pruned = Set(history.prune(
        policy: policy, now: now, recordCounts: [:], writtenAt: writtenAt, liveFingerprints: []
    ))

    // The assertion that keeps this test honest. It was previously written against the DEFAULT
    // 256 MB budget with 11-byte payloads, so nothing was ever pruned, every survivor assertion
    // held trivially, and deleting the whole anchor loop from `prune` left the test green (F233).
    #expect(!pruned.isEmpty, "nothing was pruned, so no retention rule was under test")

    // Name the survivors exactly, rather than asking whether "something older than an hour" is
    // still around — with 336 generations on disk that question answers itself.
    //
    //   hour 335, 334, 333 — rule 1, the newest three
    //   hour 335           — also the hour anchor: the newest generation at least 3600s old
    //   hour 312           — the day anchor: 24 hours back
    //   hour 168           — the week anchor: 168 hours back
    let expected = [335, 334, 333, 312, 168].compactMap { nameOfHour[$0] }
    #expect(Set(history.retained().map(\.name)) == Set(expected))
    for (label, hour) in [("hour", 335), ("day", 312), ("week", 168)] {
        let name = try #require(nameOfHour[hour])
        #expect(!pruned.contains(name), "the \(label) anchor was pruned")
    }
}

@Test("The 2026-08-14 burst survives under the SHIPPING policy, on the pin alone (F190/F235)")
func theIncidentShapeSurvivesUnderTheDefaultRetentionPolicy() throws {
    let directory = try makeHistoryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let primaryURL = directory.appendingPathComponent("meetings.json")
    let history = StoreHistory(primaryURL: primaryURL)

    // The incident, with the defaults a user actually runs — no tight budget to make the test
    // work. Ten stub generations written inside ONE launch means every generation is the same age,
    // so NO age anchor applies and rule 3 is the only thing standing between the seventeen real
    // meetings and deletion. Before F235 the byte budget was a second line of defence here; it is
    // not any more, which is exactly why this case gets its own test.
    let now = 1_757_000_000
    let real = try JSONEncoder().encode((0..<17).map { Note(title: "meeting \($0)") })
    let realName = try #require(try record(real, as: 1, into: history, directory: directory))
    var counts: [String: Int] = [realName: 17]
    var writtenAt: [String: Int] = [realName: now]
    for generation in UInt64(2)...11 {
        let name = try #require(
            try record(Data("[]".utf8), as: generation, into: history, directory: directory)
        )
        counts[name] = 0
        writtenAt[name] = now
    }

    let pruned = history.prune(
        policy: RetentionPolicy(), now: now,
        recordCounts: counts, writtenAt: writtenAt, liveFingerprints: []
    )

    #expect(!pruned.isEmpty, "nothing was pruned, so no retention rule was under test")
    #expect(!pruned.contains(realName), "the seventeen-meeting generation was lost to a save burst")
    let entry = try #require(history.retained().first { $0.name == realName })
    #expect(try JSONDecoder().decode([Note].self, from: try history.data(of: entry)).count == 17)
}

@Test("Fifty rapid saves cannot evict the age anchors or the high-water pin (F190/F233)")
func aBurstOfFiftySavesCannotEvictTheAnchors() throws {
    let directory = try makeHistoryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let primaryURL = directory.appendingPathComponent("meetings.json")
    let history = StoreHistory(primaryURL: primaryURL)

    // The incident shape at full scale, and the case plan Task 5 Step 4 asked for. Two generations
    // worth going back to — one an hour old holding seventeen meetings, one a day old — and then a
    // recovery loop that writes FIFTY blank stubs in a single launch, all stamped `now`.
    let now = 1_757_000_000
    var writtenAt: [String: Int] = [:]
    var counts: [String: Int] = [:]

    let dayOld = try #require(try record(
        paddedPayload("day", bytes: 100), as: 1, into: history, directory: directory
    ))
    writtenAt[dayOld] = now - 86_400
    counts[dayOld] = 9

    let hourOld = try #require(try record(
        paddedPayload("hour", bytes: 100), as: 2, into: history, directory: directory
    ))
    writtenAt[hourOld] = now - 3_600
    counts[hourOld] = 17

    for generation in UInt64(3)...52 {
        let name = try #require(try record(
            paddedPayload("stub-\(generation)", bytes: 100), as: generation,
            into: history, directory: directory
        ))
        writtenAt[name] = now
        counts[name] = 0
    }

    let pruned = Set(history.prune(
        policy: RetentionPolicy(), now: now,
        recordCounts: counts, writtenAt: writtenAt, liveFingerprints: []
    ))

    #expect(!pruned.isEmpty, "nothing was pruned, so no retention rule was under test")
    #expect(!pruned.contains(hourOld), "the hour anchor was evicted by a save burst")
    #expect(!pruned.contains(dayOld), "the day anchor was evicted by a save burst")

    // And the seventeen meetings are still readable, which is the whole point of keeping it.
    let entry = try #require(history.retained().first { $0.name == hourOld })
    #expect(entry.bytesMatchName)
    #expect(try history.data(of: entry) == paddedPayload("hour", bytes: 100))
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

@Test("A truncated file at a generation's own name is healed, not accepted forever (F237)")
func aTruncatedArchiveIsHealedRatherThanAcceptedAsSuccess() throws {
    let directory = try makeHistoryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let primaryURL = directory.appendingPathComponent("meetings.json")
    let history = StoreHistory(primaryURL: primaryURL)
    try FileManager.default.createDirectory(
        at: history.directoryURL, withIntermediateDirectories: true
    )

    let payload = Data("[{\"title\":\"seventeen real meetings\"}]".utf8)
    let fingerprint = StoreFingerprint.of(payload)
    let name = StoreHistory.name(generation: 1, fingerprint: fingerprint)

    // What a crash mid-`copyItem` leaves behind on a volume with no clone support: it writes the
    // destination path directly, so the wreck sits under a content-addressed name that promises
    // the whole payload. Treating "already there" as success means every later retain of this
    // generation succeeds over it and the damage is never repaired.
    try payload.prefix(5)
        .write(to: history.directoryURL.appendingPathComponent(name), options: .atomic)

    let staged = directory.appendingPathComponent("staging-1.json")
    try payload.write(to: staged, options: .atomic)
    #expect(try history.record(stagedAt: staged, generation: 1, fingerprint: fingerprint) == name)

    let entry = try #require(history.retained().first { $0.name == name })
    #expect(entry.bytesMatchName, "the truncated archive was accepted as success and never healed")
    #expect(try history.data(of: entry) == payload)
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: history.directoryURL.path) == [name],
        "healing left a temporary behind"
    )
}

@Test("A file whose name is not a real fingerprint is not a generation (F237)")
func aNonHexNameIsNotMistakenForAGeneration() throws {
    let directory = try makeHistoryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let primaryURL = directory.appendingPathComponent("meetings.json")
    let history = StoreHistory(primaryURL: primaryURL)

    let real = try #require(try record(
        Data("[{\"title\":\"ours\"}]".utf8), as: 1, into: history, directory: directory
    ))

    // `StoreFingerprint.of` is `%016llx` — sixteen LOWERCASE HEX characters, pinned by golden
    // values because it is part of the on-disk format. Counting to sixteen is not the same check:
    // it admits any stranger's file into the retained set, where pruning would then delete it.
    let impostors = [
        "g-000000002-gggggggggggggggg.json",
        "g-000000003-ZZZZZZZZZZZZZZZZ.json",
        "g-000000004-0123456789ABCDEF.json",
    ]
    for name in impostors {
        try Data("not ours".utf8)
            .write(to: history.directoryURL.appendingPathComponent(name), options: .atomic)
    }

    #expect(history.retained().map(\.name) == [real])

    let pruned = history.prune(
        policy: RetentionPolicy(recentCount: 0, ageAnchors: [], byteBudget: 0),
        now: 1_757_000_000, recordCounts: [:], writtenAt: [:], liveFingerprints: []
    )
    for name in impostors {
        #expect(!pruned.contains(name), "pruning deleted a file that was never ours")
        #expect(FileManager.default.fileExists(
            atPath: history.directoryURL.appendingPathComponent(name).path
        ))
    }
}

@Test("A history file that cannot be read is listed as damaged, not dropped (F236)")
func anUnreadableRetainedFileIsReportedRatherThanOmitted() throws {
    let directory = try makeHistoryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let primaryURL = directory.appendingPathComponent("meetings.json")
    let history = StoreHistory(primaryURL: primaryURL)

    let payload = Data("[{\"title\":\"original\"}]".utf8)
    let name = try #require(try record(payload, as: 1, into: history, directory: directory))
    let url = history.directoryURL.appendingPathComponent(name)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

    // The postmortem's lesson 5, "an error message is a promise", inverted: dropping the entry
    // tells the user the generation VANISHED, when in fact it is right there and unreadable. A
    // permission problem is fixable; a generation the recovery list never mentions is not.
    let entry = try #require(history.retained().first { $0.name == name })
    #expect(!entry.bytesMatchName)
    #expect(entry.recordCount == nil)
    #expect(entry.byteCount == payload.count, "the size is a stat away even when the bytes are not")
    #expect(throws: (any Error).self) { _ = try history.data(of: entry) }
}

/// Stamps a history file's mtime, standing in for "this generation was written then".
private func stamp(_ name: String, in history: StoreHistory, at epochSeconds: Int) throws {
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: TimeInterval(epochSeconds))],
        ofItemAtPath: history.directoryURL.appendingPathComponent(name).path
    )
}

@Test("Age anchors still hold when the ledger is gone (F234)")
func ageAnchorsFallBackToFileModificationTimeWithoutALedger() throws {
    let directory = try makeHistoryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let primaryURL = directory.appendingPathComponent("meetings.json")
    let history = StoreHistory(primaryURL: primaryURL)

    // Six generations and NO ledger at all — the hand-restore, old-bundle and deleted-sidecar
    // shapes that Invariant L exists to make safe. Design §1.2 promises a lost ledger "degrades to
    // a directory scan; it can never lose a generation", and the scan can see mtime.
    let now = 1_757_000_000
    let ages = [8 * 86_400, 3 * 86_400, 2 * 86_400, 3 * 3_600, 2 * 3_600, 0]
    var names: [String] = []
    for (index, age) in ages.enumerated() {
        let name = try #require(try record(
            Data("[{\"g\":\(index)}]".utf8), as: UInt64(index + 1),
            into: history, directory: directory
        ))
        try stamp(name, in: history, at: now - age)
        names.append(name)
    }

    let pruned = Set(history.prune(
        policy: RetentionPolicy(recentCount: 1), now: now,
        recordCounts: [:], writtenAt: [:], liveFingerprints: []
    ))

    #expect(!pruned.isEmpty, "nothing was pruned, so no retention rule was under test")
    // The newest by rule 1, then the week, day and hour anchors — all four resolved from mtime.
    #expect(Set(history.retained().map(\.name)) == Set([names[5], names[4], names[2], names[0]]))
}

@Test("The recovery list dates a generation from its file when the ledger is gone (F234)")
func retainedGenerationsFallBackToFileModificationTimeWithoutALedger() throws {
    let directory = try makeHistoryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let primaryURL = directory.appendingPathComponent("meetings.json")
    let history = StoreHistory(primaryURL: primaryURL)

    let name = try #require(try record(
        Data("[{\"title\":\"x\"}]".utf8), as: 1, into: history, directory: directory
    ))
    try stamp(name, in: history, at: 1_756_900_000)

    // "42 · 3 minutes ago · 0 meetings" is the discrimination the recovery list exists to make. A
    // missing ledger costs the record COUNT, which only the ledger knows — it must not also cost
    // the date, which the filesystem knows.
    let entry = try #require(history.retained(ledger: nil).first)
    #expect(entry.wroteAtEpochSeconds == 1_756_900_000)
    #expect(entry.recordCount == nil)
}

/// A payload of EXACTLY `bytes` bytes, so a test can state a byte budget in whole generations
/// rather than guessing at JSON overhead.
private func paddedPayload(_ marker: String, bytes: Int) -> Data {
    let prefix = "[{\"g\":\"\(marker)\",\"pad\":\""
    let suffix = "\"}]"
    let padding = String(repeating: "x", count: bytes - prefix.utf8.count - suffix.utf8.count)
    return Data((prefix + padding + suffix).utf8)
}

@Test("A generation no rule keeps is pruned even when the byte budget has room (F235)")
func theByteBudgetTrimsTheKeptSetRatherThanRescuingTheRest() throws {
    let directory = try makeHistoryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let primaryURL = directory.appendingPathComponent("meetings.json")
    let history = StoreHistory(primaryURL: primaryURL)

    var names: [String] = []
    for generation in UInt64(1)...6 {
        names.append(try #require(try record(
            paddedPayload("\(generation)", bytes: 100), as: generation,
            into: history, directory: directory
        )))
    }

    // Design §7.2 orders these: a generation is pruned when NO rule keeps it, and only THEN does
    // the budget trim what the rules kept. A budget with room left over must not resurrect an entry
    // no rule wanted — that inverts the rule into "keep everything that fits", which at the real
    // 2.1 MB index is ~120 generations per store, and the privacy bound in §13 becomes untrue.
    let pruned = Set(history.prune(
        policy: RetentionPolicy(recentCount: 1, ageAnchors: [], pinHighWaterRecordCount: false),
        now: 1_757_000_000, recordCounts: [:], writtenAt: [:], liveFingerprints: []
    ))

    #expect(pruned == Set(names.prefix(5)), "the budget rescued generations no rule kept")
    #expect(history.retained().map(\.name) == [names[5]])
}

@Test("The byte budget trims age anchors oldest-first and never rules 1, 3 or 4 (F235)")
func theByteBudgetTrimsAnchorsOldestFirstAndSparesTheOtherRules() throws {
    let directory = try makeHistoryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let primaryURL = directory.appendingPathComponent("meetings.json")
    let history = StoreHistory(primaryURL: primaryURL)

    // Four 100-byte generations, one per anchor position: a week old, two days old, two hours old,
    // and now. The two-day generation also holds the high-water record count.
    let now = 1_757_000_000
    let ages = [8 * 86_400, 2 * 86_400, 2 * 3_600, 0]
    var names: [String] = []
    var writtenAt: [String: Int] = [:]
    for (index, age) in ages.enumerated() {
        let name = try #require(try record(
            paddedPayload("\(index)", bytes: 100), as: UInt64(index + 1),
            into: history, directory: directory
        ))
        names.append(name)
        writtenAt[name] = now - age
    }

    // The rules keep all four: the newest by rule 1, the other three as the hour/day/week anchors,
    // and the two-day one also by rule 3. A budget of 250 bytes fits two of them.
    let pruned = Set(history.prune(
        policy: RetentionPolicy(recentCount: 1, byteBudget: 250),
        now: now, recordCounts: [names[1]: 17], writtenAt: writtenAt, liveFingerprints: []
    ))

    // Oldest-first among the droppable — and the two-day generation is NOT droppable even though it
    // is older than the two-hour one, because rule 3 pins it.
    #expect(pruned == [names[0], names[2]])
    #expect(history.retained().map(\.name).sorted() == [names[1], names[3]].sorted())
}
