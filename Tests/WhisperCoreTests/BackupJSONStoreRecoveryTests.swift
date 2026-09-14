import Foundation
import Testing
@testable import WhisperCore

// F190 Task 7 — the recovery table. One assertion set per interruption point, driven by
// `StoreWritePhase.allCases` so a phase added later without a recovery story fails the suite rather
// than going quietly untested.
//
// The governing rule: **`load()` writes nothing, ever, except F187's additive quarantine.** It
// classifies and reports; it never deletes a staging file, never rewrites a ledger, never repairs.
// Every repair happens inside the next `save()`, under the normal algorithm, as a new generation.
// That is the postmortem's rule — a failed load must never rebuild a library — expressed as code.
//
// Two properties fall out of the algorithm and are asserted directly for every phase:
//
//   - the primary is NEVER absent. Every install is a rename over an existing or absent name, so
//     there is no window in which meetings.json does not exist. (This is why "rename the primary
//     away into the backup" was rejected.)
//   - no interruption point makes BOTH live copies unreadable. The rotation never writes an
//     undecodable body over a decodable backup, and the primary is only replaced by a rename of a
//     fully written staging file.
//
// Genuinely red without the fix: `StoreRepair` lacks the cases these assert.

private struct Note: Codable, Equatable { let title: String }

private struct RecoveryFixture {
    let directory: URL
    let primaryURL: URL
    let backupURL: URL
    let ledgerURL: URL
}

private func makeRecoveryFixture() throws -> RecoveryFixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StoreRecovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return RecoveryFixture(
        directory: directory,
        primaryURL: directory.appendingPathComponent("meetings.json"),
        backupURL: directory.appendingPathComponent("meetings.backup.json"),
        ledgerURL: directory.appendingPathComponent("meetings.ledger.json")
    )
}

private func store(
    _ fixture: RecoveryFixture,
    io: StoreFileIO = .live,
    writer: String = "aaaa0001"
) -> BackupJSONStore<[Note]> {
    BackupJSONStore<[Note]>(
        primaryURL: fixture.primaryURL, backupURL: fixture.backupURL,
        io: io, writer: writer, recordCount: { $0.count }
    )
}

private func snapshot(of root: URL) throws -> [String: Data] {
    var files: [String: Data] = [:]
    guard let walker = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey]
    ) else { return files }
    for case let url as URL in walker {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
        files[url.path.replacingOccurrences(of: root.path + "/", with: "")] = try Data(contentsOf: url)
    }
    return files
}

@Test("Every write phase can be interrupted and the next launch still opens the library (F190)")
func everyWritePhaseRecoversOnTheNextLaunch() throws {
    for phase in StoreWritePhase.allCases {
        let fixture = try makeRecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        // Two committed generations, then a third save interrupted at `phase`.
        let seeded = store(fixture)
        _ = try seeded.save([Note(title: "gen one")])
        _ = try seeded.save([Note(title: "gen two")])
        let committed = try Data(contentsOf: fixture.primaryURL)

        let scripted = ScriptedStoreIO(failing: phase)
        let interrupted = store(fixture, io: scripted.io, writer: "bbbb0002")
        // Payloads distinct at every step so the fingerprint discriminators cannot collapse.
        _ = try? interrupted.save([Note(title: "gen three — \(phase.rawValue)")])

        // A FRESH store, as a new launch would be.
        let relaunched = store(fixture)
        let before = try snapshot(of: fixture.directory)
        let loaded = try relaunched.load()
        let after = try snapshot(of: fixture.directory)

        // The primary is never absent, whatever was interrupted.
        #expect(
            FileManager.default.fileExists(atPath: fixture.primaryURL.path),
            "\(phase.rawValue): the primary is missing"
        )
        // And the library opens: either the new generation or the committed one, never nothing.
        let result = try #require(loaded, "\(phase.rawValue): the library would not open at all")
        #expect(
            result.health == .complete || result.health == .recoveredFromBackup,
            "\(phase.rawValue): opened \(result.health)"
        )
        #expect(!result.value.isEmpty, "\(phase.rawValue): opened an empty library")

        // `load()` wrote nothing. Nothing here produces an undecodable body, so not even the
        // quarantine should have fired.
        #expect(after == before, "\(phase.rawValue): load() modified the library on disk")

        // Never both live copies unreadable.
        let primaryReadable = (try? JSONDecoder().decode(
            [Note].self, from: Data(contentsOf: fixture.primaryURL))) != nil
        let backupReadable = (try? JSONDecoder().decode(
            [Note].self, from: Data(contentsOf: fixture.backupURL))) != nil
        #expect(
            primaryReadable || backupReadable,
            "\(phase.rawValue): both live copies are unreadable"
        )
        // The committed generation survives somewhere: live, or in history.
        let retained = try relaunched.retainedGenerations()
        let committedFingerprint = StoreFingerprint.of(committed)
        #expect(
            primaryReadable || retained.contains { $0.fingerprint == committedFingerprint },
            "\(phase.rawValue): the last committed generation is gone"
        )
    }
}

@Test("A crash between install and commit adopts the installed body rather than fighting it (F190)")
func aCrashBetweenInstallAndCommitAdoptsTheBody() throws {
    let fixture = try makeRecoveryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let seeded = store(fixture)
    _ = try seeded.save([Note(title: "recorded")])

    // Interrupt at `commit`: the body is installed, the history entry exists, the ledger still
    // names the previous generation. The history entry is the proof that an F190 writer put those
    // bytes there, which is what turns an off-lineage primary into an adoption instead of a
    // divergence.
    let scripted = ScriptedStoreIO(failing: .commit)
    let crashed = store(fixture, io: scripted.io)
    let outcome = try crashed.save([Note(title: "installed but unrecorded")])
    #expect(outcome.ledgerLagged)

    let relaunched = store(fixture)
    let loaded = try #require(try relaunched.load())
    #expect(loaded.health == .complete)
    #expect(loaded.value == [Note(title: "installed but unrecorded")])
    let token = try #require(loaded.token)
    #expect(!token.verified, "the ledger does not describe these bytes, so lineage is unknown")

    // And it is writable: the adopted generation carries on normally. Note this is an ORDINARY
    // rule-4 save, not an adoption — the adoption already happened at load, which is why the token
    // is unverified. `SaveOutcome.adoptedUnrecordedPrimary` describes a save that had to adopt
    // because its own token was stale; see the next test for that path.
    let next = try relaunched.save([Note(title: "next")], expecting: token)
    #expect(next.phases.contains(.install))
    #expect(!next.adoptedUnrecordedPrimary)
    #expect(next.parent?.hasSameBody(as: token) == true)
}

@Test("A save whose token went stale to a sibling's uncommitted install adopts it (F190)")
func aStaleTokenAdoptsASiblingsUncommittedInstall() throws {
    let fixture = try makeRecoveryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let reader = store(fixture, writer: "aaaa0001")
    _ = try reader.save([Note(title: "shared base")])
    let base = try #require(try reader.load())
    let staleToken = try #require(base.token)

    // A sibling installs a new body and dies before committing the ledger. Our token is now stale,
    // so CAS rule 4 cannot fire — but rule 7 can, because the history entry proves those bytes came
    // from an F190 writer rather than from a second lineage. Adopting is the correct bias: calling
    // this a conflict would make a crashed sibling look like a competing writer.
    let scripted = ScriptedStoreIO(failing: .commit)
    let sibling = store(fixture, io: scripted.io, writer: "bbbb0002")
    _ = try sibling.save([Note(title: "sibling's uncommitted body")], expecting: staleToken)

    let outcome = try reader.save([Note(title: "ours")], expecting: staleToken)
    #expect(outcome.adoptedUnrecordedPrimary, "a crashed sibling was treated as a conflict")
    #expect(outcome.phases.contains(.install))
    let after = try #require(try reader.load())
    #expect(after.value == [Note(title: "ours")])
}

@Test("An orphaned staging file is ignored on load and swept by the next save (F190)")
func anOrphanedStagingFileIsIgnoredThenSwept() throws {
    let fixture = try makeRecoveryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let live = store(fixture)
    _ = try live.save([Note(title: "committed")])

    // What an interruption at `stage` leaves behind. It is not `meetings.json`, so load must not
    // care — but it must not accumulate either, one orphan per crash forever.
    let orphan = fixture.directory.appendingPathComponent("meetings.json.stage-deadbeef")
    try Data("[{\"title\":\"never installed\"}]".utf8).write(to: orphan, options: .atomic)

    let loaded = try #require(try live.load())
    #expect(loaded.health == .complete)
    #expect(loaded.value == [Note(title: "committed")])
    #expect(FileManager.default.fileExists(atPath: orphan.path), "load() must not delete anything")

    _ = try live.save([Note(title: "next")])
    #expect(
        !FileManager.default.fileExists(atPath: orphan.path),
        "the next save should have swept our own stale staging file"
    )
}

@Test("The sweep touches only our own temporaries, never anything else in the library (F190)")
func theSweepTouchesOnlyOurOwnTemporaries() throws {
    let fixture = try makeRecoveryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let live = store(fixture)
    _ = try live.save([Note(title: "committed")])

    // The library directory holds other stores' files, the quarantine evidence, and the recordings
    // folder. A sweep that guessed would be a second way to lose data.
    let strangers = [
        "vocabulary.json", "dictation-log.json", "meetings.unreadable-20260814T101112.json",
        "meetings.backup.json", "something-else.stage-deadbeef",
    ]
    for name in strangers {
        try Data("{}".utf8).write(to: fixture.directory.appendingPathComponent(name), options: .atomic)
    }

    _ = try live.save([Note(title: "next")])

    for name in strangers {
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.directory.appendingPathComponent(name).path
            ),
            "the sweep deleted \(name), which is not ours"
        )
    }
}

@Test("A load never writes, even when it has to fall back to the backup (F190)")
func aLoadNeverWritesEvenWhenFallingBackToTheBackup() throws {
    let fixture = try makeRecoveryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let live = store(fixture)
    _ = try live.save([Note(title: "one")])
    _ = try live.save([Note(title: "two")])

    // Corrupt only the primary, atomically, the way a foreign writer would.
    try Data("not-json".utf8).write(to: fixture.primaryURL, options: .atomic)

    let relaunched = store(fixture)
    let before = try snapshot(of: fixture.directory)
    let loaded = try #require(try relaunched.load())
    let after = try snapshot(of: fixture.directory)

    #expect(loaded.health == .recoveredFromBackup)
    #expect(loaded.value == [Note(title: "one")])
    // No token: these bytes are the BACKUP, not the primary, so they are not the generation a
    // checked save would swap against. Handing one back would let a degraded load arm a write over
    // a primary nobody read.
    #expect(loaded.token == nil)
    // The corrupt primary is still exactly as it was found — it is the evidence.
    #expect(after == before, "the load rewrote the library instead of reporting")
    #expect(try Data(contentsOf: fixture.primaryURL) == Data("not-json".utf8))
}
