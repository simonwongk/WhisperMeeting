import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F252 — the dead end a library with no retained generations reaches.
//
// The ticket asked whether an in-app folder rebuild was worth building, and the decision was no
// (see its log entry). What IS worth fixing is what the dead end says: "your recordings are
// untouched, see the documentation" leaves a user believing their transcripts died with the index.
// They did not — F198 mirrors every transcript and summary into `notes.md` beside its audio,
// precisely so the text survives an index loss, and this was the one screen that should have said
// so and didn't.

@Test("A library with no retained copies is told where its text still is")
@MainActor
func deadEndNamesTheSurvivingText() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeadEnd-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // Unreadable primary AND backup: degraded, with nothing retained to restore from.
    try Data("broken-primary".utf8).write(to: root.appendingPathComponent("meetings.json"))
    try Data("broken-backup".utf8).write(to: root.appendingPathComponent("meetings.backup.json"))

    let suite = "WhisperMeet.DeadEnd.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: suite)!
    )
    try #require(model.store.isDegraded)
    try #require(try model.store.indexGenerations().isEmpty)

    model.requestLibraryRecovery()

    let message = try #require(model.alertMessage)
    // The dead end is still stated honestly — this is not a false promise of recovery.
    #expect(message.contains("cannot be restored from inside WhisperMeet"))
    // But it names both things the user still has, which is the change.
    #expect(message.contains("notes.md"))
    #expect(message.contains("Nothing has been deleted"))
    #expect(message.contains("Recovery in the documentation"))
}
