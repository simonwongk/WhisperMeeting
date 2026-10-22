import AppKit
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F620's quit half (the user's decision of 2026-10-16: "Ask, only in that case"). A quit already saves
// a pending edit (`willTerminate` → `flushPendingWrites`, F138/F257). What was left: when that save is
// refused — another copy of WhisperMeet won a race, the disk is full, the folder cannot be written —
// the app quit anyway and the change was gone, with nothing said at the moment it was lost. A quit now
// saves first and, only when changes are still unsaved, asks "N changes could not be saved. Quit
// anyway?". An ordinary quit is unchanged.

@MainActor
@Test("A quit with nothing unsaved after its save quits at once and asks nothing (F620)")
func aQuitWithNothingUnsavedQuits() {
    let lifecycle = AppLifecycle()
    var flushes = 0
    var asked: [Int] = []
    lifecycle.changesUnsavedAfterSavingForQuit = { flushes += 1; return 0 }
    lifecycle.confirmQuitWithUnsavedChanges = { asked.append($0); return false }

    #expect(lifecycle.shouldTerminate { _ in } == .terminateNow)
    #expect(flushes == 1, "the quit did not save first")
    #expect(asked.isEmpty)
}

@MainActor
@Test("A quit whose save is refused asks, and Cancel keeps the app open (F620)", arguments: [false, true])
func aQuitWithUnsavedChangesAsks(quitAnyway: Bool) {
    let lifecycle = AppLifecycle()
    var asked: [Int] = []
    lifecycle.changesUnsavedAfterSavingForQuit = { 2 }
    lifecycle.confirmQuitWithUnsavedChanges = { asked.append($0); return quitAnyway }

    let reply = lifecycle.shouldTerminate { _ in }

    #expect(asked == [2])
    #expect(reply == (quitAnyway ? .terminateNow : .terminateCancel))
}

@MainActor
@Test("A live recording's question comes first, and its Stop & Quit path is unchanged (F620)")
func aLiveRecordingIsAskedAboutFirst() {
    let lifecycle = AppLifecycle()
    var askedUnsaved = false
    lifecycle.isRecordingLive = { true }
    lifecycle.confirmQuitDuringRecording = { .keepRecording }
    lifecycle.changesUnsavedAfterSavingForQuit = { askedUnsaved = true; return 3 }
    lifecycle.confirmQuitWithUnsavedChanges = { _ in true }

    #expect(lifecycle.shouldTerminate { _ in } == .terminateCancel)
    #expect(!askedUnsaved)
}

@MainActor
@Test("Wired to the app, a quit after a refused save counts the meeting changes and asks (F620)")
func theWiredQuitCountsRefusedMeetingChanges() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F620-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }
    let defaults = try #require(UserDefaults(suiteName: testSuiteName()))
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    let a = UUID(), b = UUID()
    model.store.upsert(MeetingRecord(id: a, title: "Standup", status: .completed))
    model.store.upsert(MeetingRecord(id: b, title: "Planning", status: .completed))
    #expect(model.store.unsavedMeetingChangeCount == 0)
    // The folder stops taking writes: the next two edits are refused at save.
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
    model.store.update(id: a) { $0.title = "Standup, renamed" }
    model.store.update(id: b) { $0.title = "Planning, renamed" }
    try #require(model.store.unsavedChanges, "fixture: the edits were saved after all")

    let lifecycle = AppLifecycle()
    var asked: [Int] = []
    lifecycle.wireQuitWithUnsavedChanges(to: model) { count, _ in asked.append(count); return false }

    // Still unwritable at the quit, so its retry (F1054) is refused too, and the question is asked.
    #expect(lifecycle.shouldTerminate { _ in } == .terminateCancel)
    #expect(asked == [2], "\(asked)")
    #expect(QuitWithUnsavedChangesAlert.message(count: 2) == "2 changes could not be saved. Quit anyway?")
    #expect(QuitWithUnsavedChangesAlert.message(count: 1) == "1 change could not be saved. Quit anyway?")
}

@Test("The app wires the unsaved-changes question into its quit (F620)")
func theAppWiresTheUnsavedChangesQuestion() throws {
    let entry = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppEntry.swift")
    #expect(entry.contains("lifecycle.wireQuitWithUnsavedChanges(to: model, dictationLog: dictation.logStore)"),
            "AppEntry does not wire the question, or not to the dictation history (F1034)")
    #expect(entry.contains("QuitWithUnsavedChangesAlert.ask(count: count, information: information)"), "AppEntry does not ask with the alert")
}

// MARK: - F1054, F1034

@MainActor
private func modelWithTwoRefusedEdits() throws -> (AppModel, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F1054-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: try #require(UserDefaults(suiteName: testSuiteName())))
    let a = UUID(), b = UUID()
    model.store.upsert(MeetingRecord(id: a, title: "Standup", status: .completed))
    model.store.upsert(MeetingRecord(id: b, title: "Planning", status: .completed))
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
    model.store.update(id: a) { $0.title = "Standup, renamed" }
    model.store.update(id: b) { $0.title = "Planning, renamed" }
    try #require(model.store.unsavedChanges, "fixture: the edits were saved after all")
    return (model, root)
}

@MainActor
@Test("A save refused earlier is tried again at quit, and a quit whose retry lands asks nothing (F1054)")
func aRefusedSaveIsRetriedAtQuit() throws {
    let (model, root) = try modelWithTwoRefusedEdits()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }
    // The cause clears (space freed, the folder writable again) while nothing pending would try again.
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
    let lifecycle = AppLifecycle()
    var asked: [Int] = []
    lifecycle.wireQuitWithUnsavedChanges(to: model) { count, _ in asked.append(count); return false }

    #expect(lifecycle.shouldTerminate { _ in } == .terminateNow, "asked \(asked)")
    #expect(MeetingStore(rootDirectory: root).meeting(id: model.store.meetings[0].id)?.title.hasSuffix("renamed") == true)
}

@MainActor
@Test("The question gives the refused save's own reason, once, and never another notice (F1054)")
func theQuestionGivesTheSavesOwnReason() throws {
    let (model, root) = try modelWithTwoRefusedEdits()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }
    let lifecycle = AppLifecycle()
    var said: [String] = []
    lifecycle.wireQuitWithUnsavedChanges(to: model) { _, information in said.append(information); return false }
    _ = lifecycle.shouldTerminate { _ in }

    // The quit's own retry was refused as well, and its reason is the one said.
    let reason = try #require(model.store.refusedSaveReason)
    let information = try #require(said.first)
    #expect(information.components(separatedBy: reason).count == 2, "the reason, once: \(information)")
    #expect(!information.contains("Meeting changes could not be saved."), "storageErrorMessage's own wording: \(information)")
    #expect(information.contains("If you quit now, those changes are lost."))
}

@MainActor
@Test("After a lost race the changes awaiting the banner are counted, and said as saved aside, not lost (F1054)")
func aLostRaceIsCountedAndSaidAsSavedAside() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F1054-race-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: try #require(UserDefaults(suiteName: testSuiteName())))
    let id = UUID()
    model.store.upsert(MeetingRecord(id: id, title: "Standup", status: .completed))
    // Another copy of the app commits through the same files, then this window's rename loses.
    let rival = BackupJSONStore<[MeetingRecord]>(
        primaryURL: root.appendingPathComponent("meetings.json"),
        backupURL: root.appendingPathComponent("meetings.backup.json"),
        writer: "ffff9999", recordCount: { $0.count }
    )
    let seen = try rival.load()
    _ = try rival.save((seen?.value ?? []).map { var r = $0; r.title = "Renamed by the other copy"; return r }, expecting: seen?.token)
    model.store.update(id: id) { $0.title = "Renamed here" }
    try #require(model.store.conflictOffer != nil, "fixture: the rename should have lost and been offered back")
    try #require(model.store.unsavedMeetingChangeCount == 0, "fixture: recovery clears the refused count")

    let lifecycle = AppLifecycle()
    var asked: [(Int, String)] = []
    lifecycle.wireQuitWithUnsavedChanges(to: model) { count, information in asked.append((count, information)); return false }
    #expect(lifecycle.shouldTerminate { _ in } == .terminateCancel, "the quit left with the banner's edit unanswered")

    let (count, information) = try #require(asked.first)
    #expect(count == 1)
    #expect(information.contains("1 meeting change is still waiting for your answer in the banner."), "\(information)")
    #expect(information.contains("saved aside as"), "where it was kept: \(information)")
    #expect(!information.contains("lost"), "it was saved aside, not lost: \(information)")
}

@MainActor
@Test("A dictation whose history entry was refused is counted at quit, retried, and said (F1034)")
func aRefusedDictationIsCountedAtQuit() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F1034-\(UUID().uuidString)", isDirectory: true)
    let logDirectory = root.appendingPathComponent("log", isDirectory: true)
    try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: logDirectory.path)
        try? FileManager.default.removeItem(at: root)
    }
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: try #require(UserDefaults(suiteName: testSuiteName())))
    let log = DictationLogStore(directory: logDirectory)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: logDirectory.path)
    log.record(text: "hello", outcome: .pasted)
    try #require(log.unsavedEntryCount == 1, "fixture: the entry was saved")

    let lifecycle = AppLifecycle()
    var asked: [(Int, String)] = []
    lifecycle.wireQuitWithUnsavedChanges(to: model, dictationLog: log) { count, information in asked.append((count, information)); return false }
    #expect(lifecycle.shouldTerminate { _ in } == .terminateCancel)
    let (count, information) = try #require(asked.first)
    #expect(count == 1)
    #expect(information.contains("1 dictation could not be added to your dictation history."), "\(information)")
    #expect(information.contains("the dictated text itself was already delivered"), "\(information)")

    // Writable again: the quit's retry saves it and asks nothing.
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: logDirectory.path)
    #expect(lifecycle.shouldTerminate { _ in } == .terminateNow)
    #expect(log.unsavedEntryCount == 0)
}
