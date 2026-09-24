import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F506 — nothing already running, and nothing started meanwhile, writes into a restored library.
//
// A transcription's result is written into its meeting by id when it finishes, whatever that
// meeting now is. So a transcription running across a restore replaced the transcript the user had
// just restored — possibly the very one the restore was meant to bring back. A summary and the
// auxiliary engine runs (second opinion, segment re-run) write back the same way.
//
// And a restore takes minutes, copying every recording twice, while the window stays usable. A
// change saved during the copy lands in files the restore is about to overwrite and misses the
// pre-restore snapshot, which was taken first — so it is lost from both.

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

private let restoredLines = [seg("What was said at the backup.", 0, 2)]

/// Holds a stubbed engine or summarizer open until the test lets it finish, so "running" is a
/// state the test controls rather than a race it hopes to win.
private actor Latch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private final class LatchedSummarizer: MeetingSummarizer, @unchecked Sendable {
    let latch: Latch
    init(_ latch: Latch) { self.latch = latch }
    func summarize(
        transcript: String, language: String?, style: SummaryStyle, template: MeetingTemplate
    ) async throws -> MeetingSummary {
        await latch.wait()
        return MeetingSummary(summary: "A summary of the old transcript", keyPoints: [], actionItems: [])
    }
}

/// A library holding one transcribed meeting, backed up, then renamed since — so the restored
/// title and transcript are distinguishable from the live ones.
@MainActor
private func makeFixture(_ label: String, latch: Latch) throws -> (root: URL, model: AppModel, generation: URL, id: UUID) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RestoreBusy-\(label)-\(UUID().uuidString)", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    let destination = root.appendingPathComponent("Dest", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let id = UUID()
    let folder = library.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: folder.appendingPathComponent("meeting.wav"))

    let model = AppModel(
        store: MeetingStore(rootDirectory: library),
        // Stubbed so a refused recording is the guard's doing, not a missing capture device.
        recorder: AudioCaptureEngine(
            stoppingCapture: {},
            finishingTracks: {},
            preservingPartialTracks: {},
            startingCapture: { _, _, _ in },
            directory: library
        ),
        defaults: UserDefaults(suiteName: "WhisperMeet.RestoreBusy.\(UUID().uuidString)")!,
        whisperExecutable: { URL(fileURLWithPath: "/tmp/whisper-stub") },
        qwenInstalled: { true }
    )
    model.runTranscriptionEngineOverride = { _, _ in
        await latch.wait()
        return TranscriptionResult(
            id: "x", text: "Transcribed from the audio before the restore.", languageCode: "en",
            audioDuration: 2, confidence: nil,
            segments: [seg("Transcribed from the audio before the restore.", 0, 2)]
        )
    }
    model.store.upsert(MeetingRecord(
        id: id, title: "At the backup", recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed, transcriptText: TranscriptFormatter.timestamped(restoredLines),
        languageCode: "en", segments: restoredLines, transcriptNormalized: true
    ))
    let summary = try BackupCoordinator.backUp(source: library, destination: destination, now: 1, retain: 3)
    let generation = destination
        .appendingPathComponent(BackupCoordinator.managedSubfolder, isDirectory: true)
        .appendingPathComponent(summary.generation, isDirectory: true)
    model.store.update(id: id) { $0.title = "Renamed since" }
    return (root, model, generation, id)
}

/// Lets every latched run finish and waits for the model to say so. The wait is a precondition of
/// nothing the tests assert about the restore; it only keeps one test's work out of the next.
@MainActor
private func drain(_ model: AppModel, _ latch: Latch) async throws {
    await latch.open()
    var ticks = 0
    while model.hasActiveTranscription || model.isRunningAuxiliaryEngine || model.isSummarizing,
          ticks < 200_000 {
        await Task.yield()
        ticks += 1
    }
    try #require(!model.hasActiveTranscription && !model.isRunningAuxiliaryEngine && !model.isSummarizing,
                 "a latched run never finished")
}

private func preRestoreSnapshots(in library: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? [])
        .filter { $0.hasPrefix(".pre-restore-") }
}

@Test("A restore is not offered while a transcription is running (F506)")
@MainActor
func restoreRefusedWhileTranscribing() async throws {
    let latch = Latch()
    let (root, model, generation, id) = try makeFixture("transcribing", latch: latch)
    defer { try? FileManager.default.removeItem(at: root) }
    model.beginTranscription(id: id)
    try #require(model.hasActiveTranscription)

    await model.requestLibraryRestore(from: generation)

    #expect(model.pendingLibraryRestore == nil, "a restore was offered over a running transcription")
    #expect(model.alertMessage?.contains("transcription") == true, "\(model.alertMessage ?? "no message")")
    try await drain(model, latch)
}

@Test("A restore confirmed after a transcription started is refused, and changes nothing (F506)")
@MainActor
func restoreRefusedAtConfirmationWhenATranscriptionStarted() async throws {
    // The offer can stand for as long as the dialog is open, and the plan's deep check alone takes
    // minutes, so "nothing was running when it was offered" says nothing about the moment of
    // confirmation. A queued transcription starts on its own when the one before it finishes.
    let latch = Latch()
    let (root, model, generation, id) = try makeFixture("confirm-transcribing", latch: latch)
    defer { try? FileManager.default.removeItem(at: root) }
    await model.requestLibraryRestore(from: generation)
    try #require(model.pendingLibraryRestore != nil)
    model.beginTranscription(id: id)
    try #require(model.hasActiveTranscription)

    let pressed = model.performLibraryRestore(confirmed: true)
    #expect(pressed == nil, "the restore started over a running transcription")
    await pressed?.value
    #expect(preRestoreSnapshots(in: model.store.rootDirectory).isEmpty, "the restore wrote into the library")
    #expect(model.alertMessage?.contains("transcription") == true, "\(model.alertMessage ?? "no message")")
    try await drain(model, latch)
}

@Test("A restore is not offered while a summary is being written (F506)")
@MainActor
func restoreRefusedWhileSummarizing() async throws {
    let latch = Latch()
    let (root, model, generation, id) = try makeFixture("summarizing", latch: latch)
    defer { try? FileManager.default.removeItem(at: root) }
    model.summarizationEngine = .local
    model.isSummarizerModelInstalled = { true }
    let summarizer = LatchedSummarizer(latch)
    model.makeSummarizer = { _, _ in summarizer }
    model.summarize(id: id)
    try #require(model.isSummarizing)

    await model.requestLibraryRestore(from: generation)

    #expect(model.pendingLibraryRestore == nil, "a restore was offered over a running summary")
    try await drain(model, latch)
}

@Test("A restore is not offered while a second opinion is running (F506)")
@MainActor
func restoreRefusedDuringAnAuxiliaryRun() async throws {
    let latch = Latch()
    let (root, model, generation, id) = try makeFixture("auxiliary", latch: latch)
    defer { try? FileManager.default.removeItem(at: root) }
    model.requestSecondOpinion(id: id)
    try #require(model.isRunningAuxiliaryEngine)

    await model.requestLibraryRestore(from: generation)

    #expect(model.pendingLibraryRestore == nil, "a restore was offered over a running second opinion")
    try await drain(model, latch)
}

@Test("While a restore is copying, the library takes no change and nothing new starts (F506)")
@MainActor
func libraryHoldsStillWhileRestoring() async throws {
    let latch = Latch()
    let (root, model, generation, id) = try makeFixture("hold", latch: latch)
    defer { try? FileManager.default.removeItem(at: root) }
    await model.requestLibraryRestore(from: generation)
    let pressed = try #require(model.performLibraryRestore(confirmed: true))

    // Nothing here has suspended, so the restore's work has not had a chance to run: every line
    // below happens while it is still to come, which is the window the user has for minutes.
    model.store.update(id: id) { $0.title = "Edited during the restore" }
    #expect(model.store.meeting(id: id)?.title == "Renamed since", "an edit was taken during the restore")
    model.beginTranscription(id: id)
    #expect(!model.hasActiveTranscription, "a transcription started during the restore")
    await model.startRecording()
    #expect(model.activeMeetingID == nil, "a recording started during the restore")

    await pressed.value
    try await drain(model, latch)
    let restored = try #require(model.store.meeting(id: id))
    #expect(restored.title == "At the backup")
    #expect(restored.segments == restoredLines, "a transcription started during the restore replaced the restored transcript")

    // The hold ends with the restore. One that outlived it would leave a library nothing can edit.
    model.store.update(id: id) { $0.title = "Edited afterwards" }
    #expect(model.store.meeting(id: id)?.title == "Edited afterwards")
}

@Test("A restore that fails lets go of the library too (F506)")
@MainActor
func failedRestoreReleasesTheLibrary() async throws {
    let latch = Latch()
    let (root, model, generation, id) = try makeFixture("failed", latch: latch)
    defer { try? FileManager.default.removeItem(at: root) }
    // Damaged at the same size, so it is offered for review and refused when applied.
    let index = generation.appendingPathComponent("meetings.json")
    var bytes = try Data(contentsOf: index)
    bytes[0] ^= 0xFF
    try bytes.write(to: index)
    await model.requestLibraryRestore(from: generation)
    try #require(model.pendingLibraryRestore?.plan.isSafeToApply == false)

    await model.performLibraryRestore(confirmed: true)?.value

    model.store.update(id: id) { $0.title = "Edited afterwards" }
    #expect(model.store.meeting(id: id)?.title == "Edited afterwards")
    await latch.open()
}

@Test("Settings says a restore is running, beside the button that started it (F506)")
func settingsShowsTheRestoreInProgress() throws {
    // The hold refuses every change for minutes; without a visible cause each refusal reads as a
    // fault. The view has no render harness (F174), so its wiring is pinned against the source,
    // comments stripped so an explanation cannot satisfy it (F285).
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let restoreButtonIsHeld = source.contains(
        "Button(\"Restore…\") { restoreLibrary() } .buttonStyle(.bordered) .disabled(model.isRestoringLibrary)"
    )
    let progressIsShown = source.contains("if model.isRestoringLibrary {")
    #expect(restoreButtonIsHeld, "Restore… stays enabled while a restore runs")
    #expect(progressIsShown, "nothing in Settings shows that a restore is running")
}
