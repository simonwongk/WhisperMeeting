import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F553 — a library whose index history cannot be kept says so, once per session.
//
// Retention is never fatal by design: when `meetings.history` cannot be used — a plain file
// squatting the name, a permissions change, a copy failing on a nearly full disk — every save still
// returns normally, and the ledger records `historyAvailable: false`, which also turns divergence
// detection off. `save()` knew (it built `.historyUnavailable` into a local `repairs` list) and threw
// the knowledge away, so the user went on believing Recover Library could undo a bad change while it
// had nothing new to go back to. The notice rides the store's existing storage-message channel:
// `ContentView`'s alert renders `storageErrorMessage`, and `AppModel.observeStorageErrors()` mirrors it
// to the windowless notification when no window is open.

@MainActor
private func makeModel(squattingHistory: Bool) throws -> (model: AppModel, root: URL, suite: String) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F553-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    if squattingHistory {
        // The ticket's reproduction: a plain FILE where the history folder should be.
        try Data("not a directory".utf8).write(to: root.appendingPathComponent("meetings.history"))
    }
    let suite = testSuiteName()
    let defaults = try #require(UserDefaults(suiteName: suite))
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    model.observeStorageErrors()
    return (model, root, suite)
}

@MainActor
@Test("A save that cannot keep index history tells the user, once per session (F553)")
func historyUnavailableIsNoticedOncePerSession() throws {
    let (model, root, suite) = try makeModel(squattingHistory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
        UserDefaults().removePersistentDomain(forName: suite)
    }
    let store = model.store
    let before = model.windowlessAlertCount

    let id = UUID()
    store.upsert(MeetingRecord(id: id, title: "First", status: .recorded))

    // The meeting WAS saved — this is a notice, not a failure, and it must not read as one.
    #expect(!store.unsavedChanges)
    #expect(MeetingStore(rootDirectory: root).meetings.map(\.title) == ["First"])
    let notice = try #require(store.storageErrorMessage, "the save that could not keep history said nothing")
    // Asked of the code rather than copied from it, except for the one fact the words must carry:
    // which folder is at fault.
    #expect(notice.contains("meetings.history"), "\(notice)")
    #expect(notice.hasPrefix(MeetingStore.historyUnavailableNotice(reason: "").prefix(40)), "\(notice)")
    #expect(model.windowlessAlertCount == before + 1, "the notice did not reach the windowless channel")
    #expect(model.lastWindowlessMessage == notice)

    // A second save in the same session, before the user has dismissed it: the notice stays up and
    // is not posted again. A save clearing it here would take it off screen before it was read.
    store.update(id: id) { $0.title = "Second" }
    #expect(store.storageErrorMessage == notice)
    #expect(model.windowlessAlertCount == before + 1, "the same notice was posted twice in one session")
    // Nor does another list's successful save clear it.
    store.addVocabulary(["Kubernetes"])
    #expect(store.storageErrorMessage == notice, "a vocabulary save took the notice off screen")
    #expect(model.windowlessAlertCount == before + 1)

    // The alert's OK. From here on this session says nothing more about it.
    store.clearStorageError()
    store.update(id: id) { $0.title = "Third" }
    #expect(store.storageErrorMessage == nil, "the notice came back after it was dismissed")
    #expect(model.windowlessAlertCount == before + 1)
}

@MainActor
@Test("A save that keeps its history says nothing (F553)")
func historyAvailableSaysNothing() throws {
    let (model, root, suite) = try makeModel(squattingHistory: false)
    defer {
        try? FileManager.default.removeItem(at: root)
        UserDefaults().removePersistentDomain(forName: suite)
    }
    let before = model.windowlessAlertCount

    let id = UUID()
    model.store.upsert(MeetingRecord(id: id, title: "First", status: .recorded))
    model.store.update(id: id) { $0.title = "Second" }

    #expect(model.store.storageErrorMessage == nil)
    #expect(model.windowlessAlertCount == before)
    #expect(try model.store.indexGenerations().count >= 2)
}

@MainActor
@Test("A history folder that can be written but not listed reaches the same notice (F688)")
func writeOnlyHistoryIsNoticed() throws {
    let (model, root, suite) = try makeModel(squattingHistory: false)
    let historyURL = root.appendingPathComponent("meetings.history", isDirectory: true)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: historyURL.path)
        try? FileManager.default.removeItem(at: root)
        UserDefaults().removePersistentDomain(forName: suite)
    }
    let id = UUID()
    model.store.upsert(MeetingRecord(id: id, title: "First", status: .recorded))
    try #require(model.store.storageErrorMessage == nil, "precondition: a healthy first save says nothing")

    try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: historyURL.path)
    try #require(
        (try? FileManager.default.contentsOfDirectory(atPath: historyURL.path)) == nil,
        "precondition: this process cannot list a 0300 folder (it would if it ran as root)"
    )
    let before = model.windowlessAlertCount
    model.store.update(id: id) { $0.title = "Second" }

    let notice = try #require(model.store.storageErrorMessage, "a write-only history folder said nothing")
    #expect(notice.contains("meetings.history"), "\(notice)")
    #expect(notice.contains("not listed"), "\(notice)")
    #expect(model.windowlessAlertCount == before + 1)
}

@Test("The notice's channel is still rendered by the window and mirrored when there is none (F553)")
func historyNoticeChannelIsReachable() throws {
    // The window cannot be rendered in this target (F174), so the reachability of the channel the
    // notice rides is asserted on source, comments stripped (F285): ContentView's one `.alert`
    // presents while `storageErrorMessage` is set and shows its text, and `observeStorageErrors()`
    // forwards the same property to the windowless notification.
    let view = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(view.contains("store.storageErrorMessage != nil"), "the alert no longer presents on a storage message")
    #expect(view.contains("[model.alertMessage, store.storageErrorMessage]"), "the alert no longer shows the storage message")
    let model = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppModel.swift")
    #expect(model.contains("store.$storageErrorMessage"), "the windowless channel no longer observes storage messages")
    let store = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/MeetingStore.swift")
    #expect(
        store.contains("storageErrorMessage = historyNotice(after: outcome.repairs)"),
        "persistMeetings no longer reads the save's repairs"
    )
}
