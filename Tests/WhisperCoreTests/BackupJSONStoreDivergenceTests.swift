import Foundation
import Testing
@testable import WhisperCore

// F190 Task 8 — divergence: two genuine lineages, neither of which we may silently discard.
//
// **The bias is explicitly toward adopting.** A false read-only library is itself a harm, and F187's
// `.suspectEmpty` over-fire already proved it — "deleted my last meeting, then crashed while
// recording" became a locked library with no in-app way out. So divergence fires only on positive
// evidence of two branches, and every one of the five conditions has a negative test here.
//
// Divergence is decided at LOAD, and it is the only thing that sets health. A save-time transition
// is forbidden: `AppModel.startRecording` pre-flights `!store.isDegraded` and relies on that answer
// for the whole recording, so a mid-session degrade would make `stopRecording`'s `upsert` silently
// return and lose a finished meeting. A save-time race uses the separate conflict channel instead.
//
// Genuinely red without the fix: there is no `.divergentGenerations`.

private struct Note: Codable, Equatable { let title: String }

private struct Fix {
    let directory: URL
    let primaryURL: URL
    let backupURL: URL
    let ledgerURL: URL
    let historyURL: URL
}

private func makeFix() throws -> Fix {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StoreDivergence-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return Fix(
        directory: directory,
        primaryURL: directory.appendingPathComponent("meetings.json"),
        backupURL: directory.appendingPathComponent("meetings.backup.json"),
        ledgerURL: directory.appendingPathComponent("meetings.ledger.json"),
        historyURL: directory.appendingPathComponent("meetings.history", isDirectory: true)
    )
}

private func store(_ fix: Fix) -> BackupJSONStore<[Note]> {
    BackupJSONStore<[Note]>(
        primaryURL: fix.primaryURL, backupURL: fix.backupURL,
        writer: "aaaa0001", recordCount: { $0.count }
    )
}

/// Two committed generations, then a foreign decodable body installed over the primary that belongs
/// to no lineage this library knows. That is the shape all five conditions describe.
private func seedTwoGenerationsThenAForeignPrimary(_ fix: Fix) throws -> Data {
    let live = store(fix)
    _ = try live.save([Note(title: "gen one")])
    _ = try live.save([Note(title: "gen two")])
    let foreign = try JSONEncoder().encode([Note(title: "a second lineage")])
    try foreign.write(to: fix.primaryURL, options: .atomic)
    return foreign
}

@Test("Two genuine lineages are reported as divergent, and neither is discarded (F190)")
func twoLineagesAreReportedAsDivergent() throws {
    let fix = try makeFix()
    defer { try? FileManager.default.removeItem(at: fix.directory) }
    let foreign = try seedTwoGenerationsThenAForeignPrimary(fix)

    let relaunched = store(fix)
    let loaded = try #require(try relaunched.load())

    #expect(loaded.health == .divergentGenerations)
    #expect(!loaded.health.allowsMutation, "a divergent library must not accept changes")
    // It returns the PRIMARY's value rather than throwing. A throw would leave
    // `MeetingStore.meetings` empty and render as zero meetings plus a read-only banner — visually
    // indistinguishable from the wipe this whole design exists to prevent.
    #expect(loaded.value == [Note(title: "a second lineage")])
    #expect(loaded.token == nil, "a divergent load must not arm a checked write")

    // Both DATA files are preserved as copies, and the originals are untouched.
    let names = try FileManager.default.contentsOfDirectory(atPath: fix.directory.path)
    #expect(names.filter { $0.contains(".unreadable-") }.count == 2)
    #expect(try Data(contentsOf: fix.primaryURL) == foreign)
    // And the other branch is still retrievable, which is what makes a choice possible at all.
    #expect(try relaunched.retainedGenerations().count >= 2)
}

@Test("No ledger is never divergence — the documented manual exit (F190)")
func deletingTheLedgerClearsDivergence() throws {
    let fix = try makeFix()
    defer { try? FileManager.default.removeItem(at: fix.directory) }
    _ = try seedTwoGenerationsThenAForeignPrimary(fix)
    #expect(try #require(try store(fix).load()).health == .divergentGenerations)

    // `docs/RECOVERY.md`'s escape hatch: quit, delete the ledger, reopen. This works only because
    // the ledger is advisory (Invariant L), and it is the reason that invariant may never be
    // relaxed — without it a divergent library would have no exit that does not involve a terminal.
    try FileManager.default.removeItem(at: fix.ledgerURL)

    let reopened = try #require(try store(fix).load())
    #expect(reopened.health == .complete)
    #expect(reopened.value == [Note(title: "a second lineage")])
    let token = try #require(reopened.token)
    #expect(!token.verified)
}

@Test("A ledger from a newer build is never divergence (F190)")
func aNewerLedgerIsNotDivergence() throws {
    let fix = try makeFix()
    defer { try? FileManager.default.removeItem(at: fix.directory) }
    _ = try seedTwoGenerationsThenAForeignPrimary(fix)
    try Data(#"{"formatVersion":9999}"#.utf8).write(to: fix.ledgerURL, options: .atomic)

    // Condition 1 fails. A build that cannot read the manifest has no basis to declare two
    // lineages, so it adopts what it can see.
    #expect(try #require(try store(fix).load()).health == .complete)
}

@Test("Divergence is never declared when there is no history to be sure with (F190)")
func noHistoryMeansNoDivergence() throws {
    let fix = try makeFix()
    defer { try? FileManager.default.removeItem(at: fix.directory) }
    _ = try seedTwoGenerationsThenAForeignPrimary(fix)

    // A plain file squatting the history name — the real-world shape on a volume that refused the
    // directory. Without the archive there is no evidence of a second branch, only an unexplained
    // primary, which is a crash far more often than a rival writer.
    //
    // Note which condition actually stops it. With the archive unreadable, condition 5 can only be
    // satisfied by `backup == ledger.current`, and condition 4 rejects exactly that — so
    // ¬2 ⇒ ¬(4 ∧ 5), and the *directory* half of condition 2 is logically redundant. It is kept as
    // an explicit guard because it states the intent, but a mutation deleting it leaves this test
    // green, and pretending otherwise would be worse than saying so. The half of condition 2 that
    // IS independently reachable is covered by the next test.
    try FileManager.default.removeItem(at: fix.historyURL)
    try Data("not a directory".utf8).write(to: fix.historyURL, options: .atomic)

    #expect(try #require(try store(fix).load()).health == .complete)
}

@Test("A writer that could not retain never causes divergence, even with a full archive (F190)")
func aLedgerThatDisclaimsHistoryNeverCausesDivergence() throws {
    let fix = try makeFix()
    defer { try? FileManager.default.removeItem(at: fix.directory) }
    let foreign = try seedTwoGenerationsThenAForeignPrimary(fix)

    // The §4 row "retain never ran (history unavailable) and then install crashed". The archive is
    // readable and still holds `current`, so conditions 3, 4 and 5 all hold — `ledger.historyAvailable`
    // is the ONLY thing standing between this and a false read-only library.
    //
    // It matters because that writer's own history entry is missing by definition, so its installed
    // primary is unrecorded through no fault of its own. Declaring divergence here would punish a
    // crash on a volume that refused a directory.
    let ledger = try #require(StoreLedger.read(at: fix.ledgerURL))
    var disclaimed = ledger
    disclaimed.historyAvailable = false
    #expect(try StoreLedger.write(disclaimed, to: fix.ledgerURL) == .written)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fix.historyURL.path).count >= 2)

    let loaded = try #require(try store(fix).load())
    #expect(loaded.health == .complete, "a writer that could not retain was treated as a rival lineage")
    #expect(loaded.value == [Note(title: "a second lineage")])
    #expect(try Data(contentsOf: fix.primaryURL) == foreign)
}

@Test("A primary whose bytes are in history is adopted, not called divergent (F190)")
func anUnrecordedPrimaryInHistoryIsAdopted() throws {
    let fix = try makeFix()
    defer { try? FileManager.default.removeItem(at: fix.directory) }
    let live = store(fix)
    _ = try live.save([Note(title: "gen one")])
    _ = try live.save([Note(title: "gen two")])

    // Condition 3 fails: the primary holds generation one's bytes, which ARE in history. That is a
    // hand-restore or a rollback, not a rival lineage.
    //
    // The bytes are COPIED from the archive rather than re-encoded. A fresh `JSONEncoder()` does not
    // reproduce the store's own encoder settings, so a re-encode is a different fingerprint and
    // would look like a third lineage — which is exactly what this test was asserting against.
    let archivedOne = try #require(
        try FileManager.default.contentsOfDirectory(atPath: fix.historyURL.path)
            .first { $0.hasPrefix("g-000000001-") }
    )
    let generationOne = try Data(contentsOf: fix.historyURL.appendingPathComponent(archivedOne))
    try generationOne.write(to: fix.primaryURL, options: .atomic)

    let loaded = try #require(try store(fix).load())
    #expect(loaded.health == .complete)
    #expect(loaded.value == [Note(title: "gen one")])
}

@Test("The legacy rotation signature is adopted, not called divergent (F190)")
func theLegacyRotationSignatureIsAdopted() throws {
    let fix = try makeFix()
    defer { try? FileManager.default.removeItem(at: fix.directory) }
    let live = store(fix)
    _ = try live.save([Note(title: "gen one")])
    _ = try live.save([Note(title: "gen two")])

    // Condition 4 fails: the backup holds exactly what the ledger calls current. An old bundle that
    // knows nothing about the ledger rotated our generation into the backup and installed its own,
    // which PROVES its primary descends from us.
    //
    // Copied from the live primary, not re-encoded, for the same reason as the test above: the
    // fingerprint has to match the ledger's `current` byte for byte.
    let generationTwo = try Data(contentsOf: fix.primaryURL)
    try generationTwo.write(to: fix.backupURL, options: .atomic)
    try JSONEncoder().encode([Note(title: "an old bundle's write")])
        .write(to: fix.primaryURL, options: .atomic)

    let loaded = try #require(try store(fix).load())
    #expect(loaded.health == .complete)
    #expect(loaded.value == [Note(title: "an old bundle's write")])
}

@Test("With no second branch left to choose, there is nothing to diverge from (F190)")
func anUnretrievableCurrentGenerationIsNotDivergence() throws {
    let fix = try makeFix()
    defer { try? FileManager.default.removeItem(at: fix.directory) }
    let live = store(fix)
    _ = try live.save([Note(title: "gen one")])
    _ = try live.save([Note(title: "gen two")])

    // Condition 5 fails: emptying the archive and overwriting both live copies leaves the ledger
    // naming bytes that exist nowhere. Reporting divergence would offer the user a choice between
    // one branch and nothing — a read-only library with no second option to pick.
    for name in try FileManager.default.contentsOfDirectory(atPath: fix.historyURL.path) {
        try FileManager.default.removeItem(at: fix.historyURL.appendingPathComponent(name))
    }
    let foreign = try JSONEncoder().encode([Note(title: "all that is left")])
    try foreign.write(to: fix.primaryURL, options: .atomic)
    try foreign.write(to: fix.backupURL, options: .atomic)

    let loaded = try #require(try store(fix).load())
    #expect(loaded.health == .complete)
    #expect(loaded.value == [Note(title: "all that is left")])
}

@Test("A divergent health can never be upgraded back to complete (F190)")
func divergenceOutranksComplete() {
    // `MeetingStore.degrade(to:)` keeps the WORST health across several stores, so a vocabulary
    // index that loaded cleanly must not lift a divergent meeting index back to writable.
    #expect(PersistedStoreHealth.divergentGenerations.isWorse(than: .complete))
    #expect(!PersistedStoreHealth.complete.isWorse(than: .divergentGenerations))
    #expect(!PersistedStoreHealth.divergentGenerations.allowsMutation)
}
