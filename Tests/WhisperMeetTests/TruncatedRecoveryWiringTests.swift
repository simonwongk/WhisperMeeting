import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F256 — the startup wiring for a rebuild that stopped early.
//
// `recover`'s own truncation arithmetic is covered in WhisperCoreTests; what these tests hold is
// the part that decides what the user SEES: which status the meeting lands in, what it is called,
// and whether the warning is persisted. All three are reachable only through
// `performStartupRecovery`, and only because `recoverInterruptedRecording` is injectable — a real
// mid-file read failure cannot be produced with a real file, which is why `mixTracks` takes its
// reads as closures in the first place.

/// An orphan folder: a UUID-named directory under `Recordings/` that the index does not know.
private func makeOrphanFolder(in root: URL) throws -> URL {
    let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
    try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    let directory = recordings.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@MainActor
private func makeModel(root: URL, suite: String) -> AppModel {
    AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: suite)!
    )
}

@Test("A partly truncated recovery is indexed with a warning naming where the audio stops")
@MainActor
func truncatedRecoveryCarriesItsWarning() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TruncatedRecoveryWiring-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try makeOrphanFolder(in: root)

    let suite = "WhisperMeet.TruncatedRecoveryWiring.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let model = makeModel(root: root, suite: suite)
    // 12 of an expected 20 minutes: short, but most of the meeting survived.
    model.recoverInterruptedRecording = { directory in
        RecoveredRecording(
            recordingURL: directory.appendingPathComponent("meeting-recovered.wav"),
            duration: 750,
            source: .rebuiltSourceTracks,
            truncatedAtSeconds: 750,
            expectedDurationSeconds: 1_200
        )
    }

    await model.performStartupRecovery()

    let meeting = try #require(model.store.meetings.first)
    // An ordinary recovery, because most of it is there — but it says where it stops.
    #expect(meeting.status == .recorded)
    #expect(meeting.title.hasPrefix("Recovered Meeting"))
    #expect(meeting.recoveryWarning?.contains("12:30") == true)
    // And the transient alert says it too, so the user learns it at the moment it happened.
    #expect(model.alertMessage?.contains("12:30") == true)
}

@Test("A rebuild that kept almost nothing is indexed as failed, not as a meeting")
@MainActor
func severelyTruncatedRecoveryIsFailed() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SevereTruncationWiring-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try makeOrphanFolder(in: root)

    let suite = "WhisperMeet.SevereTruncationWiring.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let model = makeModel(root: root, suite: suite)
    // 4 seconds of an expected 20 minutes. Titling this "Recovered Meeting" would be a lie the
    // user only discovers by pressing play.
    model.recoverInterruptedRecording = { directory in
        RecoveredRecording(
            recordingURL: directory.appendingPathComponent("meeting-recovered.wav"),
            duration: 4,
            source: .rebuiltSourceTracks,
            truncatedAtSeconds: 4,
            expectedDurationSeconds: 1_200
        )
    }

    await model.performStartupRecovery()

    let meeting = try #require(model.store.meetings.first)
    #expect(meeting.status == .failed)
    #expect(meeting.title.hasPrefix("Partly Recovered Meeting"))
    // The error explains the state; the warning gives the timing. Neither restates the other, and
    // both render in the detail view at once.
    #expect(meeting.errorMessage?.contains("still in this meeting's folder") == true)
    #expect(meeting.recoveryWarning?.contains("0:04") == true)
    // The raw tracks are the only route to the missing audio, so the folder is left alone.
    #expect(try model.store.orphanedRecordings().isEmpty)
}

@Test("A clean rebuild is indexed with no warning at all")
@MainActor
func cleanRecoveryCarriesNoWarning() async throws {
    // The counterpart: the warning's presence must mean the audio is short. A rebuild that read
    // its tracks to the end reports nothing.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CleanRecoveryWiring-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try makeOrphanFolder(in: root)

    let suite = "WhisperMeet.CleanRecoveryWiring.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let model = makeModel(root: root, suite: suite)
    model.recoverInterruptedRecording = { directory in
        RecoveredRecording(
            recordingURL: directory.appendingPathComponent("meeting-recovered.wav"),
            duration: 1_200,
            source: .rebuiltSourceTracks,
            expectedDurationSeconds: 1_200
        )
    }

    await model.performStartupRecovery()

    let meeting = try #require(model.store.meetings.first)
    #expect(meeting.status == .recorded)
    #expect(meeting.recoveryWarning == nil)
    #expect(meeting.errorMessage?.contains("Recovered from source audio") == true)
}
