import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F194 — F187 made every mutation on a damaged library safe and explained. It did not make any of
// them unavailable, and it left two ways for the read-only state to become invisible:
//
//   1. `clearStorageError()` is unguarded, so dismissing the banner erases the explanation until the
//      next refused mutation. The user is then in a read-only library with no sign of it.
//   2. `verifyLibrary()` iterates `store.meetings` without checking health, so on a library it could
//      not read it finds no meetings, finds no problems, and reports "no audio problems were found"
//      — a clean bill of health for an index that failed to decode.
//
// Genuinely red without the fix: there is no `menuFootnote`, `clearStorageError` clears
// unconditionally, and `verifyLibrary` reports clean.

@MainActor
private func makeModel(degraded: Bool) throws -> (AppModel, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReadOnlyVisibility-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    if degraded {
        try Data("broken-primary".utf8).write(to: root.appendingPathComponent("meetings.json"))
        try Data("broken-backup".utf8).write(to: root.appendingPathComponent("meetings.backup.json"))
    }
    let defaults = UserDefaults(suiteName: "F194.\(UUID().uuidString)")!
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: defaults
    )
    return (model, root)
}

@Test("Dismissing the read-only alert dismisses it, or nothing behind it is reachable (F313)")
@MainActor
func dismissingTheStorageAlertWhileDegradedClearsIt() throws {
    // F194 pinned the opposite here — "the read-only explanation was dismissed" — believing the
    // message was a banner. It is the window's one modal `.alert`, presented whenever
    // `storageErrorMessage` is non-nil, so restoring the message on dismiss reopened the alert the
    // instant it closed: three OK presses and a Return on a real screen, the same alert every time,
    // and Recover Library (F193), the restore list and the folder rebuild (F289) all behind it.
    // The standing explanation now lives on a non-modal surface — see the test below.
    let (model, root) = try makeModel(degraded: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = model.store
    #expect(store.isDegraded)

    store.update(id: UUID()) { $0.title = "x" }
    #expect(store.storageErrorMessage != nil)

    store.clearStorageError()

    #expect(store.storageErrorMessage == nil, "dismissing must dismiss, whatever the library's health")
    // And the library is still read-only — dismissing the message changed nothing about that.
    #expect(store.isDegraded)
    #expect(model.libraryReadOnlyFootnote != nil)
}

@Test("An empty flush on a read-only library raises nothing (F313)")
@MainActor
func emptyFlushWhileDegradedIsSilent() throws {
    // `AppLifecycle` flushes on every `willResignActive`. With nothing pending that is a no-op,
    // and a no-op must not set the message the window renders as a modal alert — or the alert
    // returns every time the user switches to another app, which is how it looked on screen.
    let (model, root) = try makeModel(degraded: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = model.store
    #expect(store.isDegraded)
    #expect(store.storageErrorMessage == nil || store.storageErrorMessage?.isEmpty == false)
    store.clearStorageError()

    store.flushPendingEdits()
    model.flushPendingWrites()

    #expect(store.storageErrorMessage == nil, "a flush with nothing to flush raised the read-only alert")
}

@Test("The read-only explanation stands on a surface that is not the alert (F313)")
func readOnlyNoticeIsRenderedOutsideTheAlert() throws {
    // F194's actual goal, kept: a single dismissal must not leave a read-only library with nothing
    // on screen saying so. Asserted against `ContentView`'s source with comments stripped
    // (F306's method), because there is no view harness and the model tests above cannot tell a
    // modal from a banner — which is precisely how F194 shipped a modal loop with green tests.
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/WhisperMeet/ContentView.swift")
    let source = try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : String($0) }
        .joined(separator: "\n")
    #expect(source.contains("ReadOnlyLibraryBanner(model: model)"))
    #expect(source.contains("struct ReadOnlyLibraryBanner"))
}

@Test("Dismissing the banner on a healthy library still clears it (F194)")
@MainActor
func dismissingTheStorageBannerWhenHealthyStillWorks() throws {
    let (model, root) = try makeModel(degraded: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = model.store
    #expect(!store.isDegraded)

    // A transient, non-degraded failure: a meeting whose recording path escapes the library.
    store.upsert(MeetingRecord(id: UUID(), title: "escapee", recordingPath: "../outside.wav",
                               status: .recorded))
    store.delete(id: store.meetings[0].id)
    #expect(store.storageErrorMessage != nil, "expected a transient storage message to dismiss")

    store.clearStorageError()
    #expect(store.storageErrorMessage == nil, "a healthy library must still be able to dismiss")
}

@Test("Verify Library declines to report a clean result on a library it could not read (F194)")
@MainActor
func verifyLibraryDeclinesWhileDegraded() throws {
    let (model, root) = try makeModel(degraded: true)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(model.store.isDegraded)

    model.verifyLibrary()

    let message = try #require(model.alertMessage)
    #expect(
        !message.contains("no audio problems were found"),
        "reported a clean library it never managed to read: \(message)"
    )
    #expect(message.contains(ReadOnlyLibraryNotice.lead))
}

@Test("The Improve menu carries a plain-language footnote while the library is read-only (F194)")
@MainActor
func improveMenuExplainsWhyItsActionsAreUnavailable() throws {
    let (degradedModel, degradedRoot) = try makeModel(degraded: true)
    defer { try? FileManager.default.removeItem(at: degradedRoot) }
    let (healthyModel, healthyRoot) = try makeModel(degraded: false)
    defer { try? FileManager.default.removeItem(at: healthyRoot) }

    // The footnote is what the disabled menu rows bind to. A greyed row with no explanation is the
    // thing the Improve menu's footnote convention exists to prevent (F220), and a read-only
    // library is the least guessable reason of all.
    #expect(healthyModel.libraryReadOnlyFootnote == nil)
    let footnote = try #require(degradedModel.libraryReadOnlyFootnote)
    #expect(footnote.contains(ReadOnlyLibraryNotice.lead))
    // It must say the work would be wasted, not merely that the library is damaged: these actions
    // run an on-device model for minutes and can only be applied through a refused `store.update`.
    #expect(footnote.lowercased().contains("could not be applied")
            || footnote.lowercased().contains("cannot be applied"))
}
