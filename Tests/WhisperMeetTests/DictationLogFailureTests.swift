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
