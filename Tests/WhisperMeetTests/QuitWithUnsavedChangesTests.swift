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

    #expect(lifecycle.shouldTerminate { _ in } == .terminateCancel)
    #expect(asked == [2], "\(asked)")
    #expect(QuitWithUnsavedChangesAlert.message(count: 2) == "2 changes could not be saved. Quit anyway?")
    #expect(QuitWithUnsavedChangesAlert.message(count: 1) == "1 change could not be saved. Quit anyway?")
}

@Test("The app wires the unsaved-changes question into its quit (F620)")
func theAppWiresTheUnsavedChangesQuestion() throws {
    let entry = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppEntry.swift")
    #expect(entry.contains("lifecycle.wireQuitWithUnsavedChanges(to: model)"), "AppEntry does not wire the question")
    #expect(entry.contains("QuitWithUnsavedChangesAlert.ask("), "AppEntry does not ask with the alert")
}
