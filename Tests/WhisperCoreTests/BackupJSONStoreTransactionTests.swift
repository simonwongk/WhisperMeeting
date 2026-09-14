import Foundation
import Testing
@testable import WhisperCore

// F190 Task 6 — the write algorithm and the content compare-and-swap.
//
// The governing postcondition, and the reason nothing here may be softened: `save` returns normally
// IF AND ONLY IF the value is durable at `primaryURL`. Every existing call site is
// `try store.save(x); errorMessage = nil`, so a save that returned normally without installing
// would silently report success for changes that are not on disk.
//
// Its mirror matters just as much: `commit` writes the LEDGER, after the body is already installed.
// Throwing there would show "changes could not be saved" for changes that are saved, and could
// provoke a caller rollback of durable data. A lagged ledger costs one generation of lineage
// certainty and nothing else, because the history entry identifies the generation by content.
//
// Genuinely red without the fix: there is no `save(_:expecting:)`, no `GenerationToken`, no
// `SaveOutcome`.

private struct Note: Codable, Equatable { let title: String }

private struct Fixture {
    let directory: URL
    let primaryURL: URL
    let backupURL: URL
    let ledgerURL: URL
    let historyURL: URL
}

private func makeFixture() throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StoreTransaction-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return Fixture(
        directory: directory,
        primaryURL: directory.appendingPathComponent("meetings.json"),
        backupURL: directory.appendingPathComponent("meetings.backup.json"),
        ledgerURL: directory.appendingPathComponent("meetings.ledger.json"),
        historyURL: directory.appendingPathComponent("meetings.history", isDirectory: true)
    )
}

private func makeStore(
    _ fixture: Fixture,
    io: StoreFileIO = .live,
    writer: String = "aaaa0001"
) -> BackupJSONStore<[Note]> {
    BackupJSONStore<[Note]>(
        primaryURL: fixture.primaryURL,
        backupURL: fixture.backupURL,
        io: io,
        writer: writer,
        recordCount: { $0.count }
    )
}

@Test("A save with a matching token installs the value and reports its new generation (F190)")
func aCheckedSaveInstallsAndReportsItsGeneration() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = makeStore(fixture)

    let first = try store.save([Note(title: "One")])
    #expect(first.token.sequence == 1)
    #expect(first.token.verified)
    #expect(first.phases.contains(.install))
    #expect(!first.ledgerLagged)

    let loaded = try #require(try store.load())
    #expect(loaded.value == [Note(title: "One")])
    let token = try #require(loaded.token)
    #expect(token.hasSameBody(as: first.token))

    let second = try store.save([Note(title: "Two")], expecting: token)
    #expect(second.token.sequence == 2)
    #expect(second.parent?.hasSameBody(as: token) == true)
    let afterSecond = try #require(try store.load())
    #expect(afterSecond.value == [Note(title: "Two")])
    // The outgoing generation became the backup, exactly as the pre-F190 rotation did.
    #expect(try JSONDecoder().decode([Note].self, from: Data(contentsOf: fixture.backupURL))
            == [Note(title: "One")])
}

@Test("A stale token loses the race, and the loser's work is preserved, not discarded (F190)")
func aStaleTokenConflictsAndPreservesTheLosersBody() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    // Two stores over one directory, both holding the generation-1 token. A commits; B must not
    // silently overwrite A, and B's work must not evaporate — neither update is lost.
    let writerA = makeStore(fixture, writer: "aaaa0001")
    let writerB = makeStore(fixture, writer: "bbbb0002")

    _ = try writerA.save([Note(title: "Base")])
    let base = try #require(try writerA.load())
    let sharedToken = try #require(base.token)

    let committed = try writerA.save([Note(title: "A's work")], expecting: sharedToken)

    var preservedPath: String?
    do {
        _ = try writerB.save([Note(title: "B's work")], expecting: sharedToken)
        Issue.record("B's stale save was allowed to overwrite A's generation")
    } catch let error as BackupJSONStoreError {
        guard case let .generationConflict(_, _, _, preservedAs) = error else {
            Issue.record("expected .generationConflict, got \(error)")
            return
        }
        preservedPath = preservedAs
    }

    // A's generation is the live primary and is untouched.
    let afterConflict = try #require(try writerA.load())
    #expect(afterConflict.value == [Note(title: "A's work")])
    #expect(afterConflict.token?.hasSameBody(as: committed.token) == true)

    // B's body is on disk, byte-exactly, under a name the recovery list reports.
    let name = try #require(preservedPath)
    let branchBytes = try Data(contentsOf: fixture.historyURL.appendingPathComponent(name))
    #expect(try JSONDecoder().decode([Note].self, from: branchBytes) == [Note(title: "B's work")])
    #expect(try writerA.conflictBranches().contains { $0.name == name })
}

@Test("A conflict that cannot preserve the loser's body says so rather than claiming it did (F190)")
func aConflictThatCannotPreserveFailsClosed() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let seeded = makeStore(fixture)
    _ = try seeded.save([Note(title: "Base")])
    let base = try #require(try seeded.load())
    let sharedToken = try #require(base.token)
    _ = try seeded.save([Note(title: "Winner")], expecting: sharedToken)

    // The F187 honesty rule: claim only the preservation that actually happened.
    let scripted = ScriptedStoreIO(failing: .preserveConflictBranch)
    let loser = makeStore(fixture, io: scripted.io, writer: "cccc0003")

    do {
        _ = try loser.save([Note(title: "Loser")], expecting: sharedToken)
        Issue.record("the stale save was allowed through")
    } catch let error as BackupJSONStoreError {
        guard case .generationConflictNotPreserved = error else {
            Issue.record("expected .generationConflictNotPreserved, got \(error)")
            return
        }
        let message = try #require(error.errorDescription)
        #expect(!message.lowercased().contains("was saved aside"),
                "the message claims a preservation that did not happen: \(message)")
    }
    // And the winner is still the winner.
    let stillWinner = try #require(try seeded.load())
    #expect(stillWinner.value == [Note(title: "Winner")])
}

@Test("A failed ledger commit is not an error, because the body is already durable (F190)")
func aFailedLedgerCommitIsReportedNotThrown() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let scripted = ScriptedStoreIO(failing: .commit)
    let store = makeStore(fixture, io: scripted.io)

    // Must NOT throw: `commit` runs after `install`, so the user's value is on disk. Throwing here
    // would report "changes could not be saved" for changes that were.
    let outcome = try store.save([Note(title: "Durable")])
    #expect(outcome.ledgerLagged)
    #expect(outcome.phases.contains(.install))
    #expect(try JSONDecoder().decode([Note].self, from: Data(contentsOf: fixture.primaryURL))
            == [Note(title: "Durable")])
    // And the generation is still identifiable, because the history name carries its fingerprint.
    #expect(try store.retainedGenerations().contains { $0.fingerprint == outcome.token.fingerprint })
}

@Test("A failed install throws and leaves the previous generation in place (F190)")
func aFailedInstallThrowsAndKeepsThePreviousGeneration() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let seeded = makeStore(fixture)
    _ = try seeded.save([Note(title: "Previous")])
    let before = try Data(contentsOf: fixture.primaryURL)

    let scripted = ScriptedStoreIO(failing: .install)
    let store = makeStore(fixture, io: scripted.io)
    #expect(throws: (any Error).self) { try store.save([Note(title: "Never lands")]) }

    #expect(try Data(contentsOf: fixture.primaryURL) == before)
    let survived = try #require(try seeded.load())
    #expect(survived.value == [Note(title: "Previous")])
}

@Test("A library with no ledger is adopted rather than treated as a conflict (F190)")
func aLibraryWithNoLedgerIsAdopted() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    // The pre-F190 library, and the hand-restore: two legacy files, no ledger. CAS rule 5 adopts.
    let legacy = try JSONEncoder().encode([Note(title: "Written by an older build")])
    try legacy.write(to: fixture.primaryURL, options: .atomic)
    try legacy.write(to: fixture.backupURL, options: .atomic)

    let store = makeStore(fixture)
    let loaded = try #require(try store.load())
    #expect(loaded.health == .complete)
    let token = try #require(loaded.token)
    #expect(!token.verified, "bytes no ledger described must be marked unverified")

    // Adopted generations are fully writable — that is the point of Invariant L.
    let outcome = try store.save([Note(title: "Ours")], expecting: token)
    #expect(outcome.phases.contains(.install))
    let afterAdoption = try #require(try store.load())
    #expect(afterAdoption.value == [Note(title: "Ours")])
}

@Test("A body installed but never recorded is adopted, not called a conflict (F190)")
func anInstalledButUnrecordedBodyIsAdopted() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    // Our own crash between install and commit: the primary holds an F190 body, the history has the
    // matching g- entry, and the ledger still names the previous generation. CAS rule 7 adopts,
    // because the history entry proves the body came from an F190 writer.
    let scripted = ScriptedStoreIO(failing: .commit, occurrence: 2)
    let store = makeStore(fixture, io: scripted.io)
    _ = try store.save([Note(title: "Recorded")])
    let crashed = try store.save([Note(title: "Installed but unrecorded")])
    #expect(crashed.ledgerLagged)

    let reopened = makeStore(fixture)
    let loaded = try #require(try reopened.load())
    #expect(loaded.value == [Note(title: "Installed but unrecorded")])
    let token = try #require(loaded.token)
    let outcome = try reopened.save([Note(title: "Next")], expecting: token)
    #expect(outcome.phases.contains(.install))
}

@Test("An unchecked save stays last-writer-wins, so no existing caller changes behaviour (F190)")
func anUncheckedSaveIsStillLastWriterWins() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = makeStore(fixture)
    _ = try store.save([Note(title: "One")])

    // `expecting: nil` is the compatibility default and an accepted hole, documented as such. Every
    // pre-F190 call site relies on it, so it must never start throwing a conflict.
    let outcome = try store.save([Note(title: "Two")])
    #expect(outcome.phases.contains(.install))
    let reloaded = try #require(try store.load())
    #expect(reloaded.value == [Note(title: "Two")])
}

// F236 (reported by a review of Tasks 3-5, in a file that review did not own). `conflictBranches()`
// dropped any branch it could not read. That is worse here than in `retained()`: a retained
// generation is one of several copies of a lineage, but a conflict branch is a LOSING WRITER'S WORK
// and exists nowhere else. Omitting it from the list is how it gets lost for good — the user is
// told there is nothing to resolve, and the next cleanup takes it.
//
// Skipped as root: the scenario is "the file cannot be read", staged with chmod 0o000, and root
// ignores permission bits.

@Test(
    "A conflict branch that cannot be read is still listed, never silently dropped (F190/F236)",
    .enabled(if: getuid() != 0)
)
func anUnreadableConflictBranchIsStillListed() throws {
    let fixture = try makeFixture()
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: fixture.historyURL.appendingPathComponent("unreadable").path
        )
        try? FileManager.default.removeItem(at: fixture.directory)
    }
    let store = makeStore(fixture)
    _ = try store.save([Note(title: "Base")])
    let base = try #require(try store.load())
    let sharedToken = try #require(base.token)
    _ = try store.save([Note(title: "Winner")], expecting: sharedToken)

    // Produce a real conflict branch, then make it unreadable the way a permissions problem would.
    var preserved: String?
    do {
        _ = try store.save([Note(title: "Loser")], expecting: sharedToken)
    } catch let error as BackupJSONStoreError {
        if case let .generationConflict(_, _, _, name) = error { preserved = name }
    }
    let name = try #require(preserved)
    let branchURL = fixture.historyURL.appendingPathComponent(name)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: branchURL.path)

    let branches = try store.conflictBranches()
    let entry = try #require(
        branches.first { $0.name == name },
        "the unreadable branch was dropped from the list, so the user is told there is nothing to resolve"
    )
    #expect(!entry.bytesMatchName, "an unverifiable branch must not be reported as verified")
    // Its size still comes back, from a stat rather than a read, so the list can show what is there.
    #expect(entry.byteCount > 0)
    // And the name still identifies it: the fingerprint is in the name, not only in the bytes.
    #expect(entry.fingerprint.count == 16)
}
