import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F470 — a meeting that arrived while a second opinion, segment re-run or speaker analysis held the
// engine, or while Quick Dictation ran, was refused with an alert instead of queued, and nothing
// retried it. Stop & Transcribe and every import go through `beginTranscription`, so each of them
// left the new meeting `.recorded` for good — and a stop whose capture had died said it "is being
// transcribed" on top of that.

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

/// Holds one engine pass open until the test lets it finish.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var open = false
    func enter() { lock.withLock { entered = true } }
    var hasEntered: Bool { lock.withLock { entered } }
    func release() { lock.withLock { open = true } }
    var isOpen: Bool { lock.withLock { open } }
}

/// The polled value is each caller's own subject, and a budget that runs out fails as the wait it
/// is, never as a claim about a meeting's status (AGENTS.md, "Asserting a consequence…").
@MainActor
private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    var ticks = 0
    while !condition(), ticks < 6_000 {
        try await Task.sleep(nanoseconds: 5_000_000)
        ticks += 1
    }
    try #require(condition(), "timed out waiting for \(what)")
}

private func result(_ text: String) -> TranscriptionResult {
    TranscriptionResult(id: "stub", text: text, languageCode: "en", audioDuration: 2,
                        confidence: nil, segments: [seg(text, 0, 2)])
}

/// A completed meeting whose second opinion the gate holds open, in a library whose engine probes
/// are pinned installed. Pinned through the initializer, which adopts them as the seams that
/// `refreshRuntime()` re-reads right before every automatic caller's install gate (F262). Left to the
/// real probes, this would pass or fail by what the host has installed (the F441 lesson).
@MainActor
private func makeModel(
    recorder: AudioCaptureEngine = AudioCaptureEngine(),
    root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("F470-\(UUID().uuidString)")
) throws -> (model: AppModel, heldID: UUID, gate: Gate) {
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Recordings"), withIntermediateDirectories: true)
    let defaults = try #require(UserDefaults(suiteName: "F470.\(UUID().uuidString)"))
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: recorder, defaults: defaults,
                         whisperExecutable: { URL(fileURLWithPath: "/usr/bin/true") }, qwenInstalled: { true })
    model.selectedEngine = .whisperLarge
    let heldID = UUID()
    model.store.upsert(MeetingRecord(
        id: heldID, title: "Held", recordingPath: "Recordings/\(heldID.uuidString)/meeting.wav",
        status: .completed, transcriptText: "held", segments: [seg("held", 0, 2)],
        transcriptionEngine: .whisperLarge
    ))
    let gate = Gate()
    model.runTranscriptionEngineOverride = { _, url in
        if url.path.contains(heldID.uuidString) {
            gate.enter()
            while !gate.isOpen { try await Task.sleep(nanoseconds: 2_000_000) }
            return result("held")
        }
        return result("the new meeting")
    }
    return (model, heldID, gate)
}

@MainActor
@Test("A file imported during a second opinion waits in the queue and is transcribed when it ends (F470)")
func importDuringSecondOpinionIsQueuedThenTranscribed() async throws {
    let (model, heldID, gate) = try makeModel()
    model.requestSecondOpinion(id: heldID)
    try await waitUntil("the second opinion to reach its engine") { gate.hasEntered }

    let arrivingID = UUID()
    let file = model.store.recordingDirectoryURL(for: arrivingID).appendingPathComponent("imported.m4a")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("synthetic".utf8).write(to: file)
    await model.adoptImportedRecording(id: arrivingID, at: file, title: "Arriving", knownDuration: 2)

    #expect(model.alertMessage == nil, "refused instead of queued: \(model.alertMessage ?? "")")
    #expect(model.isQueuedForTranscription(arrivingID))
    #expect(!model.hasActiveTranscription, "a transcription started on top of the second opinion (F140)")
    #expect(model.queuedTranscriptionWaitMessage.contains("second opinion"))

    gate.release()
    try await waitUntil("the queued meeting to be transcribed") {
        model.store.meeting(id: arrivingID)?.status == .completed
    }
    #expect(model.store.meeting(id: arrivingID)?.transcriptText.contains("the new meeting") == true)
}

@MainActor
@Test("Stop & Transcribe during a second opinion queues the meeting and says so, not 'is being transcribed' (F470)")
func stopDuringSecondOpinionIsQueuedAndSaysSo() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F470-stop-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = AudioCaptureEngine(
        stoppingCapture: {}, finishingTracks: {}, preservingPartialTracks: {},
        startingCapture: { _, _, _ in }, restartingCapture: { _ in }, directory: root
    )
    let (model, heldID, gate) = try makeModel(recorder: recorder, root: root)
    model.requestSecondOpinion(id: heldID)
    try await waitUntil("the second opinion to reach its engine") { gate.hasEntered }

    await model.startRecording()
    let id = try #require(model.activeMeetingID)
    try model.recorder.beginTestTrackSession(in: model.store.recordingDirectoryURL(for: id))
    try model.recorder.writeTestFrames(system: 48_000 * 3, microphone: 48_000 * 3, systemStart: 0, microphoneStart: 0)
    // A capture that died and never came back: the one stop whose alert talks about transcription.
    struct StreamDied: Error {}
    model.recorder.handleStreamFailure(StreamDied())
    #expect(await model.stopRecording(title: "Call") == id)

    #expect(model.isQueuedForTranscription(id))
    let alert = try #require(model.alertMessage)
    #expect(!alert.contains("is being transcribed"), "claimed a transcription that has not started: \(alert)")
    #expect(alert.contains("will be transcribed"), "did not say the meeting is waiting: \(alert)")

    gate.release()
    try await waitUntil("the stopped meeting to be transcribed") {
        model.store.meeting(id: id)?.status == .completed
    }
}

@MainActor
@Test("A transcription requested during Quick Dictation queues, and starts when dictation ends (F470)")
func transcriptionDuringDictationIsQueuedThenResumed() async throws {
    let (model, _, _) = try makeModel()
    var dictating = true
    model.configureDictationGuard { dictating }
    let arrivingID = UUID()
    model.store.upsert(MeetingRecord(
        id: arrivingID, title: "Arriving", recordingPath: "Recordings/\(arrivingID.uuidString)/meeting.wav",
        status: .recorded
    ))

    model.beginTranscription(id: arrivingID)

    #expect(model.alertMessage == nil, "refused instead of queued: \(model.alertMessage ?? "")")
    #expect(model.isQueuedForTranscription(arrivingID))
    #expect(!model.hasActiveTranscription, "started while Quick Dictation holds the models")
    #expect(model.queuedTranscriptionWaitMessage.contains("Quick Dictation"))

    dictating = false
    model.resumeTranscriptionQueue()
    try await waitUntil("the queued meeting to be transcribed") {
        model.store.meeting(id: arrivingID)?.status == .completed
    }
}

@MainActor
@Test("Quick Dictation reports the moment it stops being active, once per dictation (F470)")
func dictationReportsWhenItsActivityEnds() async throws {
    let suite = "F470.dictation.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("F470-dictation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    defaults.set(true, forKey: "dictationEnabled")
    defaults.set(false, forKey: "dictationAutoPaste")
    let monitor = FakeHotkeyMonitor()
    let recorder = FakeDictationRecorder(outputURL: directory.appendingPathComponent("capture.wav"))
    // Too short to transcribe, so the release discards straight back to idle.
    recorder.stopDuration = 0.1
    let controller = DictationController(
        defaults: defaults,
        engine: EmptyDictationEngine(),
        recorder: recorder,
        overlay: SilentDictationOverlay(),
        hotkeyMonitor: monitor,
        logStore: DictationLogStore(directory: directory),
        captureTimeout: .seconds(120),
        captureSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
        textInjector: isolatedTextInjector(),
        activateOnInit: false
    )
    var ended = 0
    controller.configureActivityEnded { ended += 1 }

    monitor.onPressStart?()
    try await waitUntil("the capture to start") { controller.status == .listening }
    #expect(ended == 0, "reported an end while still listening")

    monitor.onPressEnd?()
    try await waitUntil("dictation to return to idle") { controller.status == .idle }
    #expect(ended == 1)
}

// The dictation half has no caller a test can drive: `AppEntry` connects the two objects, and the
// window's status card is the only place a queued meeting says what it waits for. A suite that
// drives `resumeTranscriptionQueue` directly cannot see the hook being dropped (F306), so the
// source is asserted, comments stripped (F285).
@Test("AppEntry resumes the queue when dictation ends, and the queued card says what it waits for (F470)")
func queuedTranscriptionIsWired() throws {
    let entry = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppEntry.swift")
    #expect(entry.contains("dictation.configureActivityEnded { [weak model] in model?.resumeTranscriptionQueue() }"))
    let view = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(view.contains("Text(model.queuedTranscriptionWaitMessage)"))
    #expect(!view.contains("Waiting for the current transcription to finish."))
}
