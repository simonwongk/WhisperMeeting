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

@Test("Dismissing the banner on a read-only library keeps the explanation (F194)")
@MainActor
func dismissingTheStorageBannerWhileDegradedKeepsTheReason() throws {
    let (model, root) = try makeModel(degraded: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = model.store
    #expect(store.isDegraded)

    // Reach the banner the way a user does: attempt something, have it refused.
    store.update(id: UUID()) { $0.title = "x" }
    #expect(store.storageErrorMessage != nil)

    store.clearStorageError()

    #expect(
        store.storageErrorMessage != nil,
        "the read-only explanation was dismissed, leaving no sign the library cannot be written"
    )
    #expect(store.storageErrorMessage?.contains(ReadOnlyLibraryNotice.lead) == true)
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
