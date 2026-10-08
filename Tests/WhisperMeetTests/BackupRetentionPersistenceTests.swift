import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F461 — `backupRetention` had no `UserDefaults` backing, so the Settings picker's choice reset to
// 5 on every relaunch and the next "Back up library…" pruned generations the user had chosen to
// keep. These tests drive the real `AppModel` init over a `UserDefaults` suite exactly the way a
// relaunch would, the same pattern `LanguageWarningPersistenceTests` uses for its own setting.

@MainActor
private func model(in defaults: UserDefaults) -> AppModel {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BackupRetentionPersistenceTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
}

@MainActor
@Test("Choosing a retention survives a relaunch instead of resetting to 5 (F461)")
func chosenRetentionSurvivesARelaunch() {
    let suite = testSuiteName()
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let first = model(in: defaults)
    #expect(first.backupRetention == 5, "the documented default before any choice is made")
    first.backupRetention = 20

    // A second launch reads the same suite the first one just wrote — exactly what happens across
    // a real relaunch, and what `selectedEngine`/`linkImportEnabled` already do correctly.
    let second = model(in: defaults)
    #expect(second.backupRetention == 20, "the chosen retention must not reset to the default")
}

@MainActor
@Test("An unrecognised stored value falls back to the default rather than being trusted (F461)")
func unrecognisedStoredValueFallsBackToTheDefault() {
    let suite = testSuiteName()
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    // Not one of the picker's offered values (3/5/10/20) — a hand-edited default, or a future
    // build's leftover choice from a different offered set.
    defaults.set(7, forKey: AppModel.backupRetentionKey)

    #expect(model(in: defaults).backupRetention == 5)
}
