import Foundation
import Testing
@testable import WhisperMeet
@testable import WhisperCore

@Test("An unreadable dictation log is surfaced and never overwritten by the next dictation")
@MainActor
func unreadableDictationLogIsNotOverwritten() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetDictationLog-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let primary = root.appendingPathComponent("dictation-log.json")
    let bytes = Data("broken-log".utf8)
    try bytes.write(to: primary)

    let store = DictationLogStore(directory: root)
    #expect(store.loadErrorMessage != nil)
    #expect(!store.health.allowsMutation)

    store.record(text: "hello", outcome: .pasted)

    // The original bytes survive, preserved rather than replaced by a one-entry log.
    let quarantined = try FileManager.default.contentsOfDirectory(atPath: root.path)
        .filter { $0.contains(".unreadable-") }
    #expect(quarantined.count == 1)
    #expect(try Data(contentsOf: root.appendingPathComponent(quarantined[0])) == bytes)
    // The primary file itself, not just the copy aside: `StoreQuarantine.preserve` is idempotent per
    // byte content, so the two assertions above hold even with the `record` guard removed — only this
    // one and the emptiness check below actually fail when the guard goes (F187).
    #expect(try Data(contentsOf: primary) == bytes)
    #expect(store.log.entries.isEmpty)
}

// MARK: - F456: Clear All erases every on-disk copy, not just the primary

@Test("Clear All removes the pre-clear text from the backup and every retained history generation (F456)")
@MainActor
func clearAllErasesBackupAndHistory() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F456-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let secret = "a dictation nobody else should be able to read back"

    let store = DictationLogStore(directory: root)
    store.record(text: secret, outcome: .pasted)
    #expect(store.saveErrorMessage == nil)

    let backupURL = root.appendingPathComponent("dictation-log.backup.json")
    let historyDirectory = root.appendingPathComponent("dictation-log.history")
    // Sanity: the ordinary save path really does leave the text sitting in the backup and in a
    // retained generation — otherwise this test would pass for the wrong reason.
    #expect(try String(contentsOf: backupURL, encoding: .utf8).contains(secret))
    let generationsBefore = try FileManager.default.contentsOfDirectory(atPath: historyDirectory.path)
    #expect(!generationsBefore.isEmpty)
    #expect(try generationsBefore.contains {
        try String(contentsOf: historyDirectory.appendingPathComponent($0), encoding: .utf8).contains(secret)
    })

    let erased = store.clear()

    #expect(erased, "the removal itself must report success")
    #expect(store.log.entries.isEmpty)
    #expect(store.historyEraseFailureMessage == nil)
    #expect(!(try String(contentsOf: backupURL, encoding: .utf8).contains(secret)),
            "the backup still held the pre-clear text")
    let generationsAfter = try FileManager.default.contentsOfDirectory(atPath: historyDirectory.path)
    #expect(!generationsAfter.contains {
        (try? String(contentsOf: historyDirectory.appendingPathComponent($0), encoding: .utf8))?.contains(secret) == true
    }, "a retained generation still held the pre-clear text")
}

@Test("Clear All is reachable: the button opens a confirmation naming the count, beside the control (F456)")
func clearAllConfirmationIsReachableFromTheButton() throws {
    // `WhisperMeet` has no view-render harness (F174), so this asserts against the SOURCE rather
    // than driving the view — comments stripped first, so a paragraph describing the confirmation
    // does not satisfy the assertion in its place (F285's false positive). Through
    // `SourceAssertion` since F412: this used to cut each line at its first `//`, which missed
    // `/* */` and truncated a `//` inside a string literal.
    let stripped = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/DictationView.swift")
    #expect(stripped.contains("confirmClearHistory = true"))
    #expect(stripped.contains(".confirmationDialog("))
    #expect(stripped.contains("isPresented: $confirmClearHistory"))
    #expect(stripped.contains("log.clear()"))
}

/// A rival writer over the same files, committing a real F190 generation — mirrors
/// `MeetingStoreGenerationTests.foreignWriterCommits`, the established way this codebase produces a
/// genuine (not mocked) `generationConflict` for a store holding a now-stale token.
@MainActor
private func rivalDictationWriterCommits(_ log: DictationLog, in root: URL) throws {
    let rival = BackupJSONStore<DictationLog>(
        primaryURL: root.appendingPathComponent("dictation-log.json"),
        backupURL: root.appendingPathComponent("dictation-log.backup.json"),
        writer: "ffff9999",
        retention: .dictationLog
    )
    let existing = try rival.load()
    _ = try rival.save(log, expecting: existing?.token)
}

@Test("Clear All must not run forgetHistory() when its second save fails — a failure defers, it does not destroy (F456)")
@MainActor
func clearKeepsHistoryWhenItsSecondSaveFails() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F456-second-save-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let secret = "a dictation nobody else should be able to read back"

    let store = DictationLogStore(directory: root)
    store.record(text: secret, outcome: .pasted)
    #expect(store.saveErrorMessage == nil)

    let historyDirectory = root.appendingPathComponent("dictation-log.history")
    let generationsBeforeClear = try FileManager.default.contentsOfDirectory(atPath: historyDirectory.path)
    #expect(!generationsBeforeClear.isEmpty, "sanity: something is actually retained before Clear All runs")

    // Fires between clear()'s two internal saves. The first save (clearing the log) has already
    // succeeded and updated `store`'s in-memory token by this point; a rival now commits a
    // DIFFERENT value under that exact token, so `store`'s own second save — still expecting its
    // now-stale token — collides with a real, on-disk generation conflict. This is not a
    // permission-based failure (the existing F195 tests already cover that shape); it is the
    // transient, everyone-did-everything-right race `forgetHistory()` must still survive.
    var hookCallCount = 0
    store.betweenClearSavesForTesting = {
        hookCallCount += 1
        try? rivalDictationWriterCommits(
            DictationLog().adding(DictationLogEntry(
                id: UUID(), date: Date(), text: "a rival's own entry", outcome: .pasted,
                rawText: nil, refinement: nil
            )),
            in: root
        )
    }

    let erased = store.clear()

    #expect(hookCallCount == 1)
    #expect(store.saveErrorMessage != nil, "the second save must have actually failed")
    #expect(!erased, "a save failure must never be reported as a successful erase")
    #expect(store.historyEraseFailureMessage != nil)
    // Not a superset check: `.dictationLog`'s own retention policy (`recentCount: 2`) legitimately
    // rotates older generations out on every ordinary save, including the rival's — that happens
    // whether or not this bug is present, and is not what is under test. `forgetHistory()` is
    // categorically different: it wipes EVERY retained generation and conflict branch
    // unconditionally (`StoreHistory.forgetAll()`), which is the one way this directory ends up
    // completely empty. So an empty directory here can only mean `forgetHistory()` ran despite the
    // second save's failure.
    let generationsAfterClear = try FileManager.default.contentsOfDirectory(atPath: historyDirectory.path)
    #expect(
        !generationsAfterClear.isEmpty,
        "forgetHistory() ran and wiped every retained generation over a save failure that leaves the backup still holding the full pre-clear text with nothing left to recover it from"
    )
}

// MARK: - F195: load errors and save errors are different channels

@Test("The read-only notice is derived from health, so nothing can erase it (F195)")
@MainActor
func theLoadNoticeCannotBeErased() throws {
    // `loadErrorMessage` carried BOTH load- and save-time failures, and `persist()` cleared it on a
    // successful save. That erasure was unreachable only through a three-part unwritten invariant —
    // `health` assigned only in `init`, the load message set only under `!allowsMutation`, and
    // `allowsMutation` being exactly `== .complete`, the last of which lives in another module.
    //
    // **The fix is not to prove the invariant holds; it is to delete the state the invariant was
    // protecting.** The ticket proposed splitting the property in two, mirroring `MeetingStore`'s
    // `startupRecoveryMessages`/`storageErrorMessage`. Splitting is necessary but the stronger move
    // is available here: the load notice is a pure function of `health`, so it becomes a computed
    // property with no setter and no stored copy. There is then nothing for a stray clear to erase,
    // and the three-part invariant stops being load-bearing rather than being documented harder.
    //
    // This also avoids a test-only hook. "A successful save with a load error standing" is
    // unreachable by construction — every `persist()` caller sits behind the mutation guard — so
    // forcing it would mean adding a seam to production code to observe a state production cannot
    // reach. Deriving the value makes the property true by type instead.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F195-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("broken-log".utf8).write(to: root.appendingPathComponent("dictation-log.json"))

    let store = DictationLogStore(directory: root)
    let loadNotice = try #require(store.loadErrorMessage)

    // Every operation a degraded store accepts, and the notice is still there afterwards. Each of
    // these is refused by the mutation guard, which is the only path that used to reach `persist()`.
    store.record(text: "hello", outcome: .pasted)
    store.clear()
    store.record(text: "again", outcome: .clipboard)

    #expect(store.loadErrorMessage == loadNotice)
    #expect(store.saveErrorMessage == nil, "a refused mutation is not a save failure")
    #expect(store.log.entries.isEmpty)
}

@Test("A load failure and a save failure are independently observable (F195)")
@MainActor
func loadAndSaveFailuresAreSeparate() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F195-split-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // A healthy store: no load error.
    let store = DictationLogStore(directory: root)
    #expect(store.loadErrorMessage == nil)
    #expect(store.saveErrorMessage == nil)

    // Make the directory unwritable so the next save fails while the load stays clean.
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o500],
        ofItemAtPath: root.path
    )
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    store.record(text: "hello", outcome: .pasted)

    #expect(store.saveErrorMessage != nil, "a failed save was not reported")
    #expect(store.loadErrorMessage == nil, "a save failure was reported as a load failure")
}

@Test("A later successful save clears only the save error (F195)")
@MainActor
func aSuccessfulSaveClearsOnlyItsOwnChannel() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F195-clear-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = DictationLogStore(directory: root)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
    store.record(text: "one", outcome: .pasted)
    #expect(store.saveErrorMessage != nil)

    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    store.record(text: "two", outcome: .pasted)

    #expect(store.saveErrorMessage == nil, "a recovered save left its own error standing")
}

@Test("The store says whether a dictation would be recorded, before one is spoken (F195)")
@MainActor
func readOnlyStateIsKnowableBeforeDictating() throws {
    // The read-only banner lived under the History heading, below the dictation controls — so a
    // user held the hotkey and spoke into a log that would not record it, and found out afterwards.
    // `DictationController` calls `record` from three places, all behind the same guard, and none
    // of them can warn in advance. This is the property the UI needs to be able to ask.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F195-ro-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let healthy = DictationLogStore(directory: root)
    #expect(!healthy.historyWillNotRecord)

    try Data("broken-log".utf8).write(to: root.appendingPathComponent("dictation-log.json"))
    let degraded = DictationLogStore(directory: root)
    #expect(degraded.historyWillNotRecord)
    let warning = try #require(degraded.preDictationWarning)
    // Stated as what will happen to the next dictation, not as a description of file health: the
    // user is about to speak, and "your history is read-only" does not tell them that the words
    // they are about to say will not be kept.
    #expect(warning.contains("not be saved"))
}
