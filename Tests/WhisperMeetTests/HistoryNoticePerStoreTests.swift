import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F678 — the vocabulary, replacement-rule and dictation-log stores say when their history cannot be
// kept, as the meeting index has since F553. F679 — a save whose byte budget takes an hour, day or
// week undo point says so.
//
// `BackupJSONStore.save` returns what it worked around (`SaveOutcome.repairs`), and only
// `persistMeetings` read it: a list or the dictation log whose `<stem>.history` was squatted by a
// plain file saved normally and said nothing, so the user believed a bad change could be undone from
// history that was not being kept. Each store is its own fact, told once per session.

@MainActor
private func makeModel(squatting folders: [String]) throws -> (model: AppModel, root: URL, suite: String) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F678-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for folder in folders {
        // The F553 reproduction: a plain FILE where the history folder should be.
        try Data("not a directory".utf8).write(to: root.appendingPathComponent(folder))
    }
    let suite = testSuiteName()
    let defaults = try #require(UserDefaults(suiteName: suite))
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    model.observeStorageErrors()
    return (model, root, suite)
}

/// Waits for the main actor's queued work to set `storageErrorMessage` to something other than nil.
/// The subject of the assertion is polled against a wall-clock deadline, never a count of yields.
@MainActor
private func nextStorageMessage(_ store: MeetingStore) async -> String? {
    let deadline = Date().addingTimeInterval(30)
    while store.storageErrorMessage == nil, Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return store.storageErrorMessage
}

@MainActor
@Test("A vocabulary save that cannot keep its history tells the user, once per session (F678)")
func aVocabularyWhoseHistoryCannotBeKeptSaysSo() throws {
    let (model, root, suite) = try makeModel(squatting: ["vocabulary.history"])
    defer {
        try? FileManager.default.removeItem(at: root)
        UserDefaults().removePersistentDomain(forName: suite)
    }
    let store = model.store
    let before = model.windowlessAlertCount

    store.addVocabulary(["Kubernetes"])

    // Saved — a notice, not a failure.
    #expect(MeetingStore(rootDirectory: root).vocabulary == ["Kubernetes"])
    let notice = try #require(store.storageErrorMessage, "a vocabulary save that kept no history said nothing")
    #expect(notice.contains("vocabulary.json"), "\(notice)")
    #expect(notice.contains("vocabulary.history"), "the reason, naming the folder, is missing: \(notice)")
    #expect(!notice.contains("meeting index"), "the list's notice speaks of the meeting index: \(notice)")
    #expect(model.windowlessAlertCount == before + 1)

    store.addVocabulary(["Terraform"])
    #expect(store.storageErrorMessage == notice)
    #expect(model.windowlessAlertCount == before + 1, "the same notice was posted twice in one session")

    store.clearStorageError()
    store.addVocabulary(["Ansible"])
    #expect(store.storageErrorMessage == nil, "the notice came back after it was dismissed")
}

@MainActor
@Test("A replacement-rule save that cannot keep its history tells the user (F678)")
func replacementRulesWhoseHistoryCannotBeKeptSaySo() throws {
    let (model, root, suite) = try makeModel(squatting: ["replacement-rules.history"])
    defer {
        try? FileManager.default.removeItem(at: root)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    _ = model.store.addReplacementRule(heard: "cube ernetes", preferred: "Kubernetes")

    #expect(MeetingStore(rootDirectory: root).replacementRules.count == 1)
    let notice = try #require(model.store.storageErrorMessage, "a rule save that kept no history said nothing")
    #expect(notice.contains("replacement-rules.history"), "\(notice)")
}

@MainActor
@Test("Each store's notice is its own fact: two stores' notices are both shown, one after the other (F678)")
func eachStoreHasItsOwnNotice() async throws {
    let (model, root, suite) = try makeModel(squatting: ["meetings.history", "vocabulary.history"])
    defer {
        try? FileManager.default.removeItem(at: root)
        UserDefaults().removePersistentDomain(forName: suite)
    }
    let store = model.store

    store.upsert(MeetingRecord(id: UUID(), title: "First", status: .recorded))
    let meetingsNotice = try #require(store.storageErrorMessage)
    try #require(meetingsNotice.contains("meetings.history"), "\(meetingsNotice)")
    // The vocabulary's notice waits behind the one on screen rather than replacing it unread.
    store.addVocabulary(["Kubernetes"])
    #expect(store.storageErrorMessage == meetingsNotice, "the vocabulary's notice replaced the index's unread")

    store.clearStorageError()
    let next = try #require(await nextStorageMessage(store), "the vocabulary's notice never came")
    #expect(next.contains("vocabulary.history"), "\(next)")

    store.clearStorageError()
    store.upsert(MeetingRecord(id: UUID(), title: "Second", status: .recorded))
    store.addVocabulary(["Terraform"])
    #expect(store.storageErrorMessage == nil, "a notice came back after both were read")
}

@MainActor
@Test("The dictation history says when its past versions cannot be kept, and stops once they are (F678)")
func theDictationLogSaysWhenItsHistoryCannotBeKept() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F678-log-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let squatter = root.appendingPathComponent("dictation-log.history")
    try Data("not a directory".utf8).write(to: squatter)
    let log = DictationLogStore(directory: root)

    log.record(text: "first dictation", outcome: .pasted)

    #expect(log.saveErrorMessage == nil, "the dictation was saved; this is not a failed save")
    #expect(log.log.entries.count == 1)
    let notice = try #require(log.historyNotice, "a dictation save that kept no history said nothing")
    #expect(notice.contains("dictation-log.history"), "\(notice)")

    try FileManager.default.removeItem(at: squatter)
    log.record(text: "second dictation", outcome: .pasted)
    #expect(log.historyNotice == nil, "the notice stayed after a save kept its history again")
}

@Test("The dictation history's notice is rendered in the Dictation window (F678)")
func theDictationLogNoticeIsRendered() throws {
    // `DictationView` cannot be rendered in this target (F174); its source is asserted instead,
    // comments stripped (F285).
    let view = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/DictationView.swift")
    #expect(view.contains("if let message = log.historyNotice"), "DictationView no longer shows the history notice")
    let store = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/MeetingStore.swift")
    #expect(store.contains("historyNotice(after: outcome.repairs, of: .vocabulary)"))
    #expect(store.contains("historyNotice(after: outcome.repairs, of: .replacementRules)"))
}

// MARK: - F679

@MainActor
@Test("A save whose byte budget takes an age-anchor generation tells the user, once per session (F679)")
func aBudgetTrimIsNoticed() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F679-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = testSuiteName()
    defer {
        try? FileManager.default.removeItem(at: root)
        UserDefaults().removePersistentDomain(forName: suite)
    }
    // A one-byte budget at its ceiling, so whatever the rules keep is over it, and one hour anchor.
    let policy = RetentionPolicy(
        recentCount: 1, ageAnchors: [3_600], pinHighWaterRecordCount: false, byteBudget: 1, byteBudgetCeiling: 1
    )
    // Two earlier saves with their own dates — an hour and a half ago, and a minute ago — written the
    // way the app writes the index, so the app's next save finds an hour anchor that is not live.
    let seed = BackupJSONStore<[MeetingRecord]>(
        primaryURL: root.appendingPathComponent("meetings.json"),
        backupURL: root.appendingPathComponent("meetings.backup.json"),
        retention: policy, recordCount: { $0.count }
    )
    let now = Int(Date().timeIntervalSince1970)
    let first = MeetingRecord(id: UUID(), title: "First", status: .recorded)
    let anchor = try seed.save([first], now: now - 5_000)
    _ = try seed.save([first, MeetingRecord(id: UUID(), title: "Second", status: .recorded)],
                      expecting: anchor.token, now: now - 60)
    let anchorName = try #require(anchor.retainedName)

    let defaults = try #require(UserDefaults(suiteName: suite))
    let model = AppModel(
        store: MeetingStore(rootDirectory: root, indexRetention: policy),
        recorder: AudioCaptureEngine(), defaults: defaults
    )
    model.observeStorageErrors()
    let before = model.windowlessAlertCount
    try #require(!model.store.isDegraded, "fixture: \(model.store.health)")

    model.store.upsert(MeetingRecord(id: UUID(), title: "Third", status: .recorded))

    let history = root.appendingPathComponent("meetings.history").path
    try #require(!FileManager.default.fileExists(atPath: "\(history)/\(anchorName)"), "fixture: the budget did not trim the hour anchor")
    let notice = try #require(model.store.storageErrorMessage, "the budget took an hour anchor and nothing was said")
    #expect(notice == MeetingStore.historyTrimmedNotice(count: 1, for: .meetings), "\(notice)")
    #expect(model.windowlessAlertCount == before + 1)
    #expect(!model.store.unsavedChanges, "the save itself succeeded")

    // Once per session (the lane review's finding 3): a library past the ceiling trims on most saves,
    // and every queued copy would be another modal alert. Before each later save an hour-old
    // generation is planted in the history, as a ledger that lost track of it would leave one, so
    // each of those saves trims an hour anchor again — and is required to, so a save that happened
    // not to trim cannot pass for one that stayed quiet.
    var planted = 0
    func plantedURL() -> URL {
        let bytes = Data("[{\"planted\":\(planted)}]".utf8)
        return URL(fileURLWithPath: history)
            .appendingPathComponent("g-\(String(format: "%09d", planted))-\(StoreFingerprint.of(bytes)).json")
    }
    func plantAnHourOldGeneration() throws {
        planted += 1
        let url = plantedURL()
        try Data("[{\"planted\":\(planted)}]".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -5_000)], ofItemAtPath: url.path)
    }
    func trimmedAgain() -> Bool { !FileManager.default.fileExists(atPath: plantedURL().path) }
    let id = UUID()
    try plantAnHourOldGeneration()
    model.store.upsert(MeetingRecord(id: id, title: "Fourth", status: .recorded))
    try #require(trimmedAgain(), "fixture: the second save did not trim")
    try plantAnHourOldGeneration()
    model.store.update(id: id) { $0.title = "Fourth, renamed" }
    try #require(trimmedAgain(), "fixture: the third save did not trim")
    #expect(model.store.storageErrorMessage == notice, "a later trimming save changed what is on screen")
    #expect(model.windowlessAlertCount == before + 1, "a later trimming save posted the notice again")
    model.store.clearStorageError()
    try plantAnHourOldGeneration()
    model.store.update(id: id) { $0.title = "Fourth, renamed again" }
    try #require(trimmedAgain(), "fixture: the fourth save did not trim")
    #expect(model.store.storageErrorMessage == nil, "the trim notice came back after it was read")
    #expect(model.windowlessAlertCount == before + 1)
}

@MainActor
@Test("The trim notice names no control a writable library does not show (F679)")
func theTrimNoticeNamesNoHiddenControl() {
    // It follows a successful save, so the library is writable, and Recover Library appears only while
    // the library cannot be read (`ContentView`, `AppModel.requestLibraryRecovery`) — the reason
    // F553's notice "names no control".
    for store in [MeetingStore.HistoryStore.meetings, .vocabulary, .replacementRules] {
        for count in [1, 3] {
            let notice = MeetingStore.historyTrimmedNotice(count: count, for: store)
            #expect(!notice.contains("Recover Library"), "\(store): \(notice)")
        }
    }
}
