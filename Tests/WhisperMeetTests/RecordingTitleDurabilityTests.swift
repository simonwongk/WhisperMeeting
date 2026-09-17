import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F298 — the title a user types before recording lived in `@State private var title` in
// `ContentView`, reaching the model only as an argument to `stopRecording(title:)`. So it existed
// nowhere but the view until the recording ended, and `AppModel`'s own comment on the live-marker
// path said as much: "there is nothing here to persist yet".
//
// Small and annoying rather than dangerous, but it is the one field distinguishing two meetings
// recorded on the same afternoon — and F258 built a sidecar whose `title` every caller wrote empty,
// which is a field that looks supported and is not.
//
// Two halves, both covered here: the title reaches the sidecar while recording, and recovery reads
// it back instead of synthesising a name over it.

@MainActor
private func makeTitleModel() throws -> (AppModel, URL, UserDefaults, String) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecordingTitleDurability-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "F298.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    // The capture seams stand in for a display and a microphone, as `CaptureRestartWiringTests`
    // does: this is about what reaches disk beside the audio, not about the audio.
    let recorder = AudioCaptureEngine(
        stoppingCapture: {},
        finishingTracks: {},
        preservingPartialTracks: {},
        startingCapture: { _, _, _ in },
        restartingCapture: { _ in },
        directory: root
    )
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: recorder,
        defaults: defaults,
        whisperExecutable: { URL(fileURLWithPath: "/tmp/whisper-stub") },
        qwenInstalled: { true }
    )
    return (model, root, defaults, suite)
}

/// An interrupted capture folder with a sidecar, as F258 leaves it — with a title this time.
private func makeInterruptedFolder(in root: URL, title: String) throws -> UUID {
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let samples = [Float](repeating: 0.25, count: 96_000)
    try samples.withUnsafeBytes {
        try Data($0).write(to: folder.appendingPathComponent("system-audio.f32"))
    }
    let session = RecordingSession(
        id: id, startedAt: Date().addingTimeInterval(-300), title: title, markers: []
    )
    try RecordingSessionSidecar.write(session, in: folder)
    return id
}

// MARK: - The write half

@MainActor
@Test("A title set before recording is on disk once recording starts (F298)")
func titleSetBeforeStartReachesTheSidecar() async throws {
    let (model, root, defaults, suite) = try makeTitleModel()
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    model.recordingTitle = "Board call"
    await model.startRecording()
    let id = try #require(model.activeMeetingID)

    let session = try #require(
        RecordingSessionSidecar.read(in: model.store.recordingDirectoryURL(for: id))
    )
    #expect(session.title == "Board call")
}

@MainActor
@Test("A title typed after recording has started also reaches the sidecar (F298)")
func titleTypedWhileRecordingReachesTheSidecar() async throws {
    // The common case, and the one a start-only write would miss: people press record and name the
    // meeting while it runs.
    let (model, root, defaults, suite) = try makeTitleModel()
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    await model.startRecording()
    let id = try #require(model.activeMeetingID)
    model.recordingTitle = "Vendor review"

    let session = try #require(
        RecordingSessionSidecar.read(in: model.store.recordingDirectoryURL(for: id))
    )
    #expect(session.title == "Vendor review")
}

@MainActor
@Test("A later sidecar write does not erase the title (F298)")
func anotherSidecarWriteKeepsTheTitle() async throws {
    // F284's lesson, applied to the new field: a whole-file write erased whatever it did not know
    // about. The title is model-owned and mirrored on every write, so a marker drop or a sleep note
    // must carry it rather than blank it.
    let (model, root, defaults, suite) = try makeTitleModel()
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    model.recordingTitle = "Standup"
    await model.startRecording()
    let id = try #require(model.activeMeetingID)
    model.addLiveMarker(label: "one")

    let session = try #require(
        RecordingSessionSidecar.read(in: model.store.recordingDirectoryURL(for: id))
    )
    #expect(session.title == "Standup")
    #expect(!session.markers.isEmpty, "the marker write is what this test needs to have happened")
}

@MainActor
@Test("Clearing the title clears it on disk rather than leaving a stale name (F298)")
func clearingTheTitleClearsTheSidecar() async throws {
    // The title is a mirror of the model, like `markers`. A user who deletes what they typed has
    // said the meeting has no name, and recovery must not resurrect a name they removed.
    let (model, root, defaults, suite) = try makeTitleModel()
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    model.recordingTitle = "Wrong name"
    await model.startRecording()
    let id = try #require(model.activeMeetingID)
    model.recordingTitle = ""

    let session = try #require(
        RecordingSessionSidecar.read(in: model.store.recordingDirectoryURL(for: id))
    )
    #expect(session.title.isEmpty)
}

// MARK: - The read half

@MainActor
@Test("A recovered meeting keeps the title the user typed (F298)")
func recoveryPrefersTheSidecarTitle() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TitleRecovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = try makeInterruptedFolder(in: root, title: "Q3 planning with Priya")

    let suite = "F298.recovery.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: suite)!
    )
    await model.performStartupRecovery()

    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.title == "Q3 planning with Priya")
    #expect(!meeting.title.hasPrefix("Recovered Meeting"))
}

@MainActor
@Test("A recovery with no title still gets the synthesized name (F298)")
func recoveryWithoutATitleStillNamesTheMeeting() async throws {
    // The behaviour that must not regress: an untitled recording still comes back identifiable, so
    // the read-back has to distinguish "no title" from "a title that happens to be empty".
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TitleRecoveryEmpty-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = try makeInterruptedFolder(in: root, title: "")

    let suite = "F298.recoveryEmpty.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: suite)!
    )
    await model.performStartupRecovery()

    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.title.hasPrefix("Recovered Meeting"))
}

@MainActor
@Test("A whitespace-only title is treated as no title (F298)")
func whitespaceTitleIsNotATitle() async throws {
    // Otherwise a recovered meeting is named " " — present, useless, and impossible to tell from a
    // rendering bug in the sidebar.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TitleRecoveryBlank-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = try makeInterruptedFolder(in: root, title: "   \n ")

    let suite = "F298.recoveryBlank.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: suite)!
    )
    await model.performStartupRecovery()

    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.title.hasPrefix("Recovered Meeting"))
}

/// Writes a raw track into a live recording's folder, so a finalize has something to rebuild.
///
/// Without it `stopRecording` finds no audio, saves no meeting, and reports the no-usable-audio
/// failure over whatever the finalize had already said — which is how the first draft of these two
/// tests failed for a reason that had nothing to do with what they were testing.
@MainActor
private func writeTrack(for id: UUID, in model: AppModel) throws {
    let folder = model.store.recordingDirectoryURL(for: id)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let samples = [Float](repeating: 0.25, count: 96_000)
    try samples.withUnsafeBytes {
        try Data($0).write(to: folder.appendingPathComponent("system-audio.f32"))
    }
}

// MARK: - The interruption paths that end a recording (F298, found reviewing F294)

@MainActor
@Test("A recording ended by a dead capture keeps its title (F298)")
func aFinalizedRecordingKeepsItsTitle() async throws {
    // The hole in F298's first pass. Moving the title onto the model fixed the *sidecar*, but the
    // two paths that end a recording without the user pressing stop still called
    // `stopRecording(title: "")` — and the comment above each said why: "the title lives in
    // `ContentView`'s `@State` and never reaches the model". That was true when written and false
    // an hour later, which is the whole reason a comment stating a constraint has to be re-read
    // when the constraint moves.
    //
    // So the meeting the user gets back from a lid close was named "Recording <date>" even though
    // they had typed a name, which is precisely the case F298 exists for.
    let (model, root, defaults, suite) = try makeTitleModel()
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    model.recordingTitle = "Client call"
    await model.startRecording()
    let id = try #require(model.activeMeetingID)
    try writeTrack(for: id, in: model)
    model.recorder.handleStreamFailure(AudioCaptureError.noDisplayAvailable)

    // Over the padding cap, so the policy finalizes instead of restarting — the path that saves
    // what was captured and ends the recording.
    await model.handleCaptureInterruption(
        trigger: .didWake,
        gap: CaptureRestartPolicy.defaultMaximumPaddedGap + 60,
        now: Date()
    )

    #expect(!model.recordingState.isLive, "the recording should have been finalized")
    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.title == "Client call")
}

@MainActor
@Test("A recording ended by a dead capture tells a windowless user it ended (F294)")
func finalizeReachesAWindowlessUser() async throws {
    // F294. `finalizeAfterFailedRestart` set only `captureRestartNotice`, a published property the
    // window renders — so a user recording from the menu bar with no window open was told nothing
    // when their recording *ended* because the display went away. That is the highest-stakes
    // message in the app and it was the one F257's channel did not carry.
    //
    // Asserted on `alertMessage` rather than on the notification: `report(_:)` sets both, and the
    // notification half is behind `NSApp`, which is nil here. The windowless decision itself is
    // covered by `WindowlessAlertTests`.
    let (model, root, defaults, suite) = try makeTitleModel()
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    await model.startRecording()
    let id = try #require(model.activeMeetingID)
    try writeTrack(for: id, in: model)
    model.recorder.handleStreamFailure(AudioCaptureError.noDisplayAvailable)
    await model.handleCaptureInterruption(
        trigger: .didWake,
        gap: CaptureRestartPolicy.defaultMaximumPaddedGap + 60,
        now: Date()
    )

    // Two things are legitimately reported in this flow — the finalize notice, then the
    // recovered-after-an-abnormal-finish message — and `alertMessage` holds the last. My first
    // assertion required it to equal `captureRestartNotice`, which assumed a single message; that
    // was a wrong expectation of mine, not a defect. What matters is the substance: a user with no
    // window open is told the recording ended *and* that the audio was kept.
    let message = try #require(model.alertMessage, "the user was never told the recording ended")
    #expect(
        message.contains("recovered and added to history") || message.contains("saved"),
        "the message must say the audio was kept, not only that something went wrong: \(message)"
    )
    #expect(model.captureRestartNotice != nil, "the banner is still set for a user who has a window")
}
