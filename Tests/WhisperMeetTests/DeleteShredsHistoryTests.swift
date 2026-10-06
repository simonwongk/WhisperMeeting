import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F295 — delete means delete, after a grace window. The immediate variant was tried first and
// `restoringAGenerationBringsTheLibraryBack` (F190) showed the cost: a library wiped by seventeen
// deletes could no longer be brought back. So the text stays recoverable for the retention policy's
// own week and is then scrubbed from every generation and the backup — the "Recently Deleted" shape
// every mainstream app uses. Decided 2026-09-17 under the user's delegation.

@MainActor
private func makeLibrary(_ label: String) throws -> (MeetingStore, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeleteShred-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (MeetingStore(rootDirectory: root), root)
}

private func allIndexText(in root: URL) throws -> [String: String] {
    var out: [String: String] = [:]
    for name in ["meetings.json", "meetings.backup.json"] {
        let url = root.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) {
            out[name] = try String(contentsOf: url, encoding: .utf8)
        }
    }
    let history = root.appendingPathComponent("meetings.history")
    for name in (try? FileManager.default.contentsOfDirectory(atPath: history.path)) ?? [] {
        out["history/\(name)"] = try String(contentsOf: history.appendingPathComponent(name), encoding: .utf8)
    }
    return out
}

private let week = Int(MeetingStore.shredGracePeriod)

@MainActor
@Test("Inside the grace window a deleted meeting is still in the history, so a mistaken delete can be undone (F295)")
func deletedMeetingStaysRecoverableInsideTheWindow() throws {
    let (store, root) = try makeLibrary("window")
    defer { try? FileManager.default.removeItem(at: root) }
    let secret = UUID()
    store.upsert(MeetingRecord(id: UUID(), title: "Standup", status: .completed, transcriptText: "ordinary"))
    store.upsert(MeetingRecord(id: secret, title: "Board review", status: .completed,
                               transcriptText: "the confidential-kestrel figures"))

    store.delete(id: secret)

    #expect(try allIndexText(in: root).values.contains { $0.contains("confidential-kestrel") })
    #expect(store.pendingShreds.keys.contains(secret))
    #expect(store.processPendingShreds(now: Int(Date().timeIntervalSince1970) + week / 2).isEmpty,
            "half a week in, nothing is due")
    // The recovery list can still bring it back.
    let target = try #require(try store.indexGenerations().first { $0.recordCount == 2 })
    try store.restoreIndexGeneration(target)
    #expect(store.meetings.contains { $0.id == secret })
}

@MainActor
@Test("After the grace window the text is gone from the index, the backup and every generation (F295)")
func deletedMeetingIsShreddedAfterTheWindow() throws {
    let (store, root) = try makeLibrary("after")
    defer { try? FileManager.default.removeItem(at: root) }
    let secret = UUID()
    store.upsert(MeetingRecord(id: UUID(), title: "Standup", status: .completed, transcriptText: "ordinary"))
    store.upsert(MeetingRecord(id: secret, title: "Board review", status: .completed,
                               transcriptText: "the confidential-kestrel figures", notes: "private note"))
    store.upsert(MeetingRecord(id: UUID(), title: "Planning", status: .completed, transcriptText: "later"))
    store.delete(id: secret)

    let shredded = store.processPendingShreds(now: Int(Date().timeIntervalSince1970) + week + 1)

    #expect(shredded == [secret])
    let after = try allIndexText(in: root)
    for (name, text) in after {
        #expect(!text.contains("confidential-kestrel"), "\(name) still holds the transcript")
        #expect(!text.contains("private note"), "\(name) still holds the notes")
        #expect(!text.contains("Board review"), "\(name) still holds the title")
    }
    // The other meetings are still in history: this is a shred, not Forget History.
    #expect(after.values.contains { $0.contains("Standup") })
    #expect(store.pendingShreds.isEmpty, "the queue entry is consumed")
    #expect(store.storageErrorMessage?.contains("could not be removed from the saved index history") != true)
    // And the store keeps working: the next save must not lose a compare-and-swap to its own rotation.
    store.upsert(MeetingRecord(id: UUID(), title: "After", status: .completed, transcriptText: "x"))
    #expect(store.storageErrorMessage == nil)
    #expect(store.meetings.count == 3)
}

@MainActor
@Test("A batch delete queues every removed meeting, and one pass shreds them all (F295)")
func batchDeleteQueuesAndShredsAll() throws {
    let (store, root) = try makeLibrary("batch")
    defer { try? FileManager.default.removeItem(at: root) }
    let a = UUID(), b = UUID()
    store.upsert(MeetingRecord(id: a, title: "Alpha-secret", status: .completed, transcriptText: "alpha text"))
    store.upsert(MeetingRecord(id: b, title: "Beta-secret", status: .completed, transcriptText: "beta text"))
    store.upsert(MeetingRecord(id: UUID(), title: "Gamma", status: .completed, transcriptText: "gamma text"))

    _ = store.delete(ids: [a, b])
    #expect(Set(store.pendingShreds.keys) == [a, b])
    let shredded = store.processPendingShreds(now: Int(Date().timeIntervalSince1970) + week + 1)

    #expect(Set(shredded) == [a, b])
    let after = try allIndexText(in: root)
    #expect(!after.values.contains { $0.contains("Alpha-secret") || $0.contains("Beta-secret") })
    #expect(after.values.contains { $0.contains("Gamma") })
}

@MainActor
@Test("The queue survives a relaunch, so a shred due next week happens next week (F295)")
func pendingShredsPersistAcrossLaunches() throws {
    let (store, root) = try makeLibrary("relaunch")
    defer { try? FileManager.default.removeItem(at: root) }
    let secret = UUID()
    store.upsert(MeetingRecord(id: secret, title: "Board review", status: .completed, transcriptText: "confidential-kestrel"))
    store.upsert(MeetingRecord(id: UUID(), title: "Standup", status: .completed, transcriptText: "ordinary"))
    store.delete(id: secret)

    let reopened = MeetingStore(rootDirectory: root)
    #expect(reopened.pendingShreds.keys.contains(secret))
    #expect(reopened.processPendingShreds(now: Int(Date().timeIntervalSince1970) + week + 1) == [secret])
    #expect(!(try allIndexText(in: root).values.contains { $0.contains("confidential-kestrel") }))
}

// MARK: - F498: the undo the window exists for, and a queue file nobody vouched for

/// A library where "Board review" was deleted by mistake: its text is still in the history, and its
/// shred is queued.
@MainActor
private func makeMistakenDelete(_ label: String) throws -> (MeetingStore, URL, UUID) {
    let (store, root) = try makeLibrary(label)
    let secret = UUID()
    store.upsert(MeetingRecord(id: UUID(), title: "Standup", status: .completed, transcriptText: "ordinary"))
    store.upsert(MeetingRecord(id: secret, title: "Board review", status: .completed,
                               transcriptText: "the confidential-kestrel figures"))
    store.delete(id: secret)
    try #require(store.pendingShreds.keys.contains(secret))
    return (store, root, secret)
}

private func historyHolds(_ needle: String, in root: URL) throws -> Bool {
    try allIndexText(in: root).contains { $0.key.hasPrefix("history/") && $0.value.contains(needle) }
}

@MainActor
@Test("A meeting brought back from the recovery list is not shredded a week later (F498)")
func restoredMeetingIsNotShredded() throws {
    let (store, root, secret) = try makeMistakenDelete("restored")
    defer { try? FileManager.default.removeItem(at: root) }

    // The undo F295's window exists for.
    let target = try #require(try store.indexGenerations().first { $0.recordCount == 2 })
    try store.restoreIndexGeneration(target)
    try #require(store.meetings.contains { $0.id == secret })
    let generations = Set(try store.indexGenerations().map(\.name))

    let shredded = store.processPendingShreds(now: Int(Date().timeIntervalSince1970) + week + 1)

    #expect(shredded.isEmpty, "a meeting the user brought back is live, not deleted")
    #expect(store.pendingShreds.isEmpty, "its shred is cancelled, not left queued to fire later")
    // A shred re-records every generation that held the meeting under a new name, so the same
    // names still being there is the proof nothing was rewritten.
    #expect(generations.isSubset(of: Set(try store.indexGenerations().map(\.name))),
            "the generations holding a live meeting were rewritten")
    #expect(store.meetings.contains { $0.id == secret })
}

@MainActor
@Test("A meeting brought back by a whole-library restore is not shredded either (F498)")
func meetingRestoredFromABackupIsNotShredded() throws {
    let (store, root) = try makeLibrary("backup")
    defer { try? FileManager.default.removeItem(at: root) }
    let secret = UUID()
    store.upsert(MeetingRecord(id: UUID(), title: "Standup", status: .completed, transcriptText: "ordinary"))
    store.upsert(MeetingRecord(id: secret, title: "Board review", status: .completed,
                               transcriptText: "the confidential-kestrel figures"))
    // What last night's backup holds. `meetings.pending-shred.json` is not in a backup, so the
    // live queue survives the restore that replaces the index underneath it.
    let backedUp = try Data(contentsOf: root.appendingPathComponent("meetings.json"))
    store.delete(id: secret)
    try backedUp.write(to: root.appendingPathComponent("meetings.json"))
    store.reloadAfterLibraryRestore()
    try #require(store.meetings.contains { $0.id == secret })
    try #require(!store.isDegraded)
    let generations = Set(try store.indexGenerations().map(\.name))

    let shredded = store.processPendingShreds(now: Int(Date().timeIntervalSince1970) + week + 1)

    #expect(shredded.isEmpty)
    #expect(store.pendingShreds.isEmpty)
    #expect(generations.isSubset(of: Set(try store.indexGenerations().map(\.name))))
}

/// `UUID(uuidString:)` reads either case, so one id spelled two ways is ONE key — and
/// `Dictionary(uniqueKeysWithValues:)` traps on it. The getter runs at every launch, from
/// `performStartupRecovery`, so the file took the app down before a window could explain anything.
@MainActor
@Test("A queue naming one meeting in two spellings is read as one entry, not a crash (F498)")
func caseVariantQueueKeysAreOneEntry() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeleteShred-case-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let file = #"{"\#(id.uuidString.lowercased())":1000,"\#(id.uuidString)":2000}"#
    try Data(file.utf8).write(to: root.appendingPathComponent("meetings.pending-shred.json"))

    let store = MeetingStore(rootDirectory: root)

    // The later deletion time, so the shred waits for the later of the two: nothing is lost by
    // waiting, and shredding early is the one direction that cannot be taken back.
    #expect(store.pendingShreds == [id: 2000])
}

@MainActor
@Test("A deletion time far in the past is due, and its arithmetic cannot trap (F498)")
func deletionTimeAtIntMinIsDueWithoutTrapping() throws {
    let (store, root, secret) = try makeMistakenDelete("intmin")
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"{"\#(secret.uuidString)":\#(Int.min)}"#.utf8)
        .write(to: root.appendingPathComponent("meetings.pending-shred.json"))

    let shredded = store.processPendingShreds(now: Int(Date().timeIntervalSince1970))

    #expect(shredded == [secret])
    #expect(!(try historyHolds("confidential-kestrel", in: root)))
    #expect(store.pendingShreds.isEmpty)
}

/// A deletion dated in the future — a clock that was set wrong, a file from somewhere else — would
/// defer its shred until then, which for `Int.max` is forever. Deferring forever is itself the
/// failure: the text stays in the history the user was told it would leave.
@MainActor
@Test("A deletion dated in the future still comes due, a week after it is first seen (F498, F603)")
func futureDeletionTimeIsClampedToNow() throws {
    let (store, root, secret) = try makeMistakenDelete("future")
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"{"\#(secret.uuidString)":\#(Int.max)}"#.utf8)
        .write(to: root.appendingPathComponent("meetings.pending-shred.json"))
    let now = Int(Date().timeIntervalSince1970)

    #expect(store.processPendingShreds(now: now).isEmpty, "not due yet: the window starts now")
    // F603: the deletion's own date is never rewritten from `now` — only when it was first seen
    // dated beyond the week is recorded, beside it — so a clock that is wrong at this launch
    // cannot move a real deletion into the past.
    #expect(store.pendingShreds == [secret: Int.max], "the recorded deletion date was rewritten")
    #expect(store.processPendingShreds(now: now + week - 1).isEmpty, "a second early")
    #expect(store.processPendingShreds(now: now + week) == [secret])
    #expect(!(try historyHolds("confidential-kestrel", in: root)))
}

// MARK: - F552: the shred's rotation adopts only this session's own lineage

/// The shred used to end by re-saving whatever the primary held and then adopting that generation's
/// token unconditionally. When another copy of the app had committed since this session's last
/// save, that told this session it had read the other copy's commit — it had not — and its next save
/// passed the compare-and-swap and overwrote the other copy's work unseen.
@MainActor
@Test("A shred does not let this session's next save overwrite another copy's commit (F552)")
func shredDoesNotAdoptAnotherCopysCommit() throws {
    let (store, root, secret) = try makeMistakenDelete("rival")
    defer { try? FileManager.default.removeItem(at: root) }
    let deletedAt = try #require(store.pendingShreds[secret])
    // Another copy of the app, having read this session's delete, adds a meeting of its own.
    let rival = BackupJSONStore<[MeetingRecord]>(
        primaryURL: root.appendingPathComponent("meetings.json"),
        backupURL: root.appendingPathComponent("meetings.backup.json"),
        writer: "ffff9999",
        recordCount: { $0.count }
    )
    let seen = try #require(try rival.load())
    let theirs = MeetingRecord(id: UUID(), title: "The other copy's meeting", status: .completed)
    try rival.save(seen.value + [theirs], expecting: seen.token)

    try #require(store.processPendingShreds(now: deletedAt + week) == [secret])
    store.upsert(MeetingRecord(id: UUID(), title: "This session's next meeting", status: .completed))

    #expect(MeetingStore(rootDirectory: root).meeting(id: theirs.id) != nil,
            "this session's next save overwrote the other copy's commit without a conflict")
}

/// The guard itself (review round 1: the test above no longer reaches it, because since F552 the
/// shred rotates only when the backup still holds the deleted meeting, and another copy's ordinary
/// save rotates it out first). What does reach it is a primary replaced WITHOUT a rotation: the
/// hand restore `docs/RECOVERY.md` describes — copy an older index over `meetings.json`, remove the
/// ledger — done while this session is running and before its shred. The rotation then re-saves
/// content this session never read; adopting that generation let the session's next save pass the
/// compare-and-swap and write its stale list over the restored one.
@MainActor
@Test("The shred's rotation is not adopted when it re-saved content this session never read (F552)")
func shredRotationOverAHandRestoredIndexIsNotAdopted() throws {
    let (store, root, secret) = try makeMistakenDelete("hand-restore")
    defer { try? FileManager.default.removeItem(at: root) }
    let deletedAt = try #require(store.pendingShreds[secret])
    let backupURL = root.appendingPathComponent("meetings.backup.json")
    try #require(String(decoding: try Data(contentsOf: backupURL), as: UTF8.self).contains("confidential-kestrel"),
                 "fixture: the delete was the last save, so the backup still holds the meeting")
    // The hand restore: an index this session never read, with no ledger to describe it.
    let restored = MeetingRecord(id: UUID(), title: "Restored by hand", status: .completed)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(store.meetings + [restored]).write(to: root.appendingPathComponent("meetings.json"))
    try FileManager.default.removeItem(at: root.appendingPathComponent("meetings.ledger.json"))

    try #require(store.processPendingShreds(now: deletedAt + week) == [secret])
    try #require(!String(decoding: try Data(contentsOf: backupURL), as: UTF8.self).contains("confidential-kestrel"),
                 "fixture: the rotation must have run for the guard to matter")
    store.upsert(MeetingRecord(id: UUID(), title: "This session's next meeting", status: .completed))

    #expect(MeetingStore(rootDirectory: root).meeting(id: restored.id) != nil,
            "this session's next save wrote its stale list over the hand-restored index")
    #expect(store.conflictOffer != nil, "the stale save should have lost the race and been offered back (F642)")
}

// MARK: - F680: a rotation skipped over an index that did not load cleanly keeps the id queued

/// F680's guard skips the backup rotation when the index does not load as `.complete`. The first cut
/// still took the id out of the queue, so the backup kept the deleted text with nothing left to
/// remove it — and the next launch's own load copied that backup aside as a quarantine copy that
/// nothing queued either (lane C review round 2, probe P2). The id now stays queued while the backup
/// still holds it, so the next pass over a clean load finishes the job.
@MainActor
@Test("A shred whose backup rotation is skipped keeps the id queued while the backup still holds it (F680)")
func skippedRotationKeepsTheIDQueued() throws {
    let (store, root, secret) = try makeMistakenDelete("skipped-rotation")
    defer { try? FileManager.default.removeItem(at: root) }
    let deletedAt = try #require(store.pendingShreds[secret])
    let primaryURL = root.appendingPathComponent("meetings.json")
    let backupURL = root.appendingPathComponent("meetings.backup.json")
    let ownPrimary = try Data(contentsOf: primaryURL)
    // A primary no save recorded, beside the ledger that still describes the last one — an index
    // copied in by hand while this session runs. The library is divergent from here on.
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(store.meetings + [MeetingRecord(id: UUID(), title: "Written elsewhere", status: .completed)])
        .write(to: primaryURL)

    let shredded = store.processPendingShreds(now: deletedAt + week)

    #expect(shredded.isEmpty, "reported as shredded while the backup still holds it")
    #expect(store.pendingShreds[secret] == deletedAt, "the id left the queue with the text still in the backup")
    #expect(String(decoding: try Data(contentsOf: backupURL), as: UTF8.self).contains("confidential-kestrel"),
            "fixture: the rotation was skipped")
    #expect(!(try historyHolds("confidential-kestrel", in: root)), "the history itself is shredded either way")
    let relaunched = MeetingStore(rootDirectory: root)
    #expect(relaunched.isDegraded)
    #expect(relaunched.pendingShreds[secret] == deletedAt, "the queue did not survive the relaunch")

    // The divergence resolved — here by putting this session's own save back — and the next pass
    // rotates the backup and lets the id go.
    try ownPrimary.write(to: primaryURL)
    let resolved = MeetingStore(rootDirectory: root)
    try #require(!resolved.isDegraded)
    #expect(resolved.processPendingShreds(now: deletedAt + week + 60) == [secret])
    #expect(!String(decoding: try Data(contentsOf: backupURL), as: UTF8.self).contains("confidential-kestrel"))
    #expect(resolved.pendingShreds.isEmpty)
}

/// The other half of F680 (review round 2, probe P5): over a primary that does not decode, `load()`
/// answers with the backup — the generation from BEFORE the delete — and the old unchecked rotation
/// saved that as the live index, putting the deleted meeting back.
@MainActor
@Test("A shred over a primary that does not decode never puts the deleted meeting back (F680)")
func shredOverATornPrimaryDoesNotResurrect() throws {
    let (store, root, secret) = try makeMistakenDelete("torn-primary")
    defer { try? FileManager.default.removeItem(at: root) }
    let deletedAt = try #require(store.pendingShreds[secret])
    let primaryURL = root.appendingPathComponent("meetings.json")
    try Data("{ torn".utf8).write(to: primaryURL)

    _ = store.processPendingShreds(now: deletedAt + week)

    #expect(!String(decoding: try Data(contentsOf: primaryURL), as: UTF8.self).contains("confidential-kestrel"),
            "the shred's rotation put the deleted meeting back in the live index")
    #expect(store.pendingShreds[secret] == deletedAt, "the backup still holds it, so it stays queued")
}

// MARK: - F603: a clock that is behind at one launch must not shorten the week

/// F498 wrote `min(deletedAt, now)` back to disk at every launch, so one launch with the clock
/// behind — unsynced after an SMC reset, set back by hand — permanently re-dated a recent deletion
/// into the past, and once the clock was right again the shred fired early. Early is the direction
/// that cannot be taken back: the week is the undo window. Three days behind is a clock nobody
/// notices; thirty is one that makes the real deletion date look "beyond now + a week", which is
/// the case the ticket's own proposed rule still re-dated.
@MainActor
@Test("A launch with the clock behind does not make a later shred fire early (F603)",
      arguments: [3, 30])
func clockBehindAtOneLaunchDoesNotShortenTheWeek(daysBehind: Int) throws {
    let (store, root, secret) = try makeMistakenDelete("behind-\(daysBehind)")
    defer { try? FileManager.default.removeItem(at: root) }
    let deletedAt = try #require(store.pendingShreds[secret])
    let day = 86_400

    // One launch with the clock behind: nothing is due — and nothing about the deletion may be
    // rewritten from that clock.
    #expect(store.processPendingShreds(now: deletedAt - daysBehind * day).isEmpty)
    #expect(store.pendingShreds[secret] == deletedAt,
            "the deletion was re-dated from a clock that was behind")

    // The clock syncs. Four days after the delete the week is not over, whatever that launch saw.
    #expect(store.processPendingShreds(now: deletedAt + 4 * day).isEmpty,
            "shredded four days after the delete, inside the undo window")
    #expect(try historyHolds("confidential-kestrel", in: root))

    // A week after the delete it goes, on the deletion's own date.
    #expect(store.processPendingShreds(now: deletedAt + week) == [secret])
    #expect(!(try historyHolds("confidential-kestrel", in: root)))
}

/// The queue file is read by every build a user might launch, so the sighting F603 adds must not
/// change what an earlier build reads from it (the F188 rule, applied to a sidecar). This is the
/// F498 reader, verbatim: it keeps the UUID keys and drops anything else.
@MainActor
@Test("An earlier build reads the same deletions from a queue that now carries a sighting (F603)")
func earlierBuildReadsTheQueueUnchanged() throws {
    let (store, root, secret) = try makeMistakenDelete("wire")
    defer { try? FileManager.default.removeItem(at: root) }
    let deletedAt = try #require(store.pendingShreds[secret])
    // Thirty days behind: the real deletion date is beyond the week, so a sighting is written.
    _ = store.processPendingShreds(now: deletedAt - 30 * 86_400)

    let data = try Data(contentsOf: root.appendingPathComponent("meetings.pending-shred.json"))
    let raw = try JSONDecoder().decode([String: Int].self, from: data)
    try #require(raw.count == 2, "the fixture must carry a sighting beside the deletion: \(raw)")
    let earlierBuild = Dictionary(
        raw.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } },
        uniquingKeysWith: max
    )
    #expect(earlierBuild == [secret: deletedAt])
}

/// The bound F498 exists for survives F603, including a first sighting from a clock that was
/// itself ahead: a wait dated beyond the week is believed no more than a deletion dated there.
@MainActor
@Test("A future deletion first seen by a clock that was ahead is still due within a week of the clock being right (F603)")
func futureDeletionFirstSeenByAClockAheadIsStillBounded() throws {
    let (store, root, secret) = try makeMistakenDelete("ahead")
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"{"\#(secret.uuidString)":\#(Int.max)}"#.utf8)
        .write(to: root.appendingPathComponent("meetings.pending-shred.json"))
    let now = Int(Date().timeIntervalSince1970)
    let year = 365 * 86_400

    #expect(store.processPendingShreds(now: now + year).isEmpty, "seen first by a clock a year ahead")
    #expect(store.processPendingShreds(now: now).isEmpty, "the clock is right again; the week starts now")
    #expect(store.processPendingShreds(now: now + week) == [secret])
    #expect(!(try historyHolds("confidential-kestrel", in: root)))
}
