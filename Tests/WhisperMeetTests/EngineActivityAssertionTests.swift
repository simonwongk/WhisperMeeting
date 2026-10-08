import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F560 — no power/idle-sleep assertion was held during transcription, Second Opinion, a segment
// re-run, or speaker analysis; only the capture held one (`AudioCaptureEngine.beginRecordingActivity`,
// F254). A user stopped a 5-hour meeting at 6pm, left the lid open, and the Mac idle-slept a few
// minutes into the Whisper Large pass that runs after Stop.
//
// Each of the four heavy engine passes now runs inside `AppModel.withEngineActivityHeld`, which begins
// the assertion before the pass and releases it on every exit — success, cancellation, or a thrown
// error — via `defer`. Every assertion below drives the real user-triggerable entry point
// (`beginTranscription`, `requestSecondOpinion`/`computeSecondOpinion`, `requestSegmentReTranscription`,
// `requestSpeakerDiarization`) with `beginEngineActivity`/`endEngineActivity` swapped for counting
// stubs — the F47/F254 seam style — never a real OS power assertion, which no test can observe.

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

/// Counts begin/end calls and their pairing. A class so the `@Sendable` closures can write into it.
private final class ActivityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _beginCount = 0
    private var _endCount = 0
    private var _reasons: [String] = []
    private var _live = 0
    var beginCount: Int { lock.withLock { _beginCount } }
    var endCount: Int { lock.withLock { _endCount } }
    var reasons: [String] { lock.withLock { _reasons } }
    var live: Int { lock.withLock { _live } }

    func begin(_ reason: String) -> NSObjectProtocol? {
        lock.withLock { _beginCount += 1; _reasons.append(reason); _live += 1 }
        return NSObject()
    }
    func end() {
        lock.withLock { _endCount += 1; _live -= 1 }
    }
}

@MainActor
private func attachActivityBox(to model: AppModel) -> ActivityBox {
    let box = ActivityBox()
    model.beginEngineActivity = { reason in box.begin(reason) }
    model.endEngineActivity = { _ in box.end() }
    return box
}

/// A model pinned as "installed" on every host, including a bare CI runner, so a request reaches the
/// engine seam instead of stopping at an install gate.
@MainActor
private func makeModel() -> AppModel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F560-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root.appendingPathComponent("Recordings"), withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: testSuiteName())!
    return AppModel(
        store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults,
        whisperExecutable: { URL(fileURLWithPath: "/usr/bin/true") }, qwenInstalled: { true }
    )
}

/// The polled value is each caller's own subject; an exhausted budget fails as the wait it is
/// (AGENTS.md: require the precondition rather than asserting past it).
@MainActor
private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    var ticks = 0
    while !condition(), ticks < 6_000 {
        try await Task.sleep(nanoseconds: 5_000_000)
        ticks += 1
    }
    try #require(condition(), "timed out waiting for \(what)")
}

// MARK: - Transcription

@MainActor
@Test("A transcription holds the idle-sleep assertion for its life and releases it on success (F560)")
func transcriptionReleasesActivityOnSuccess() async throws {
    let model = makeModel()
    let box = attachActivityBox(to: model)
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "M", recordingPath: "Recordings/\(id.uuidString)/meeting.wav", status: .recorded
    ))
    model.selectedEngine = .whisperLarge
    model.runTranscriptionEngineOverride = { _, _ in
        TranscriptionResult(id: "x", text: "hello", languageCode: "en", audioDuration: 1, confidence: nil, segments: [seg("hello", 0, 1)])
    }

    model.beginTranscription(id: id)
    try await waitUntil("the transcription to finish") { !model.hasActiveTranscription }

    #expect(model.store.meeting(id: id)?.status == .completed)
    #expect(box.beginCount == 1)
    #expect(box.endCount == 1)
    #expect(box.live == 0)
    #expect(box.reasons == ["Transcribing a meeting"])
}

@MainActor
@Test("A transcription that throws still releases the idle-sleep assertion (F560)")
func transcriptionReleasesActivityOnError() async throws {
    let model = makeModel()
    let box = attachActivityBox(to: model)
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "M", recordingPath: "Recordings/\(id.uuidString)/meeting.wav", status: .recorded
    ))
    model.selectedEngine = .whisperLarge
    struct EngineDown: Error {}
    model.runTranscriptionEngineOverride = { _, _ in throw EngineDown() }

    model.beginTranscription(id: id)
    try await waitUntil("the transcription to finish") { !model.hasActiveTranscription }

    #expect(model.store.meeting(id: id)?.status == .failed)
    #expect(box.beginCount == 1)
    #expect(box.endCount == 1)
    #expect(box.live == 0)
}

// MARK: - Second opinion

@MainActor
@Test("A second opinion releases the idle-sleep assertion on success (F560)")
func secondOpinionReleasesActivityOnSuccess() async throws {
    let model = makeModel()
    let box = attachActivityBox(to: model)
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "M", recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed, transcriptText: "hello", segments: [seg("hello", 0, 1)]
    ))
    model.runTranscriptionEngineOverride = { _, _ in
        TranscriptionResult(id: "x", text: "hello", languageCode: "en", audioDuration: 1, confidence: nil, segments: [seg("hello", 0, 1)])
    }

    await model.computeSecondOpinion(id: id)

    #expect(model.secondOpinionSpans != nil)
    #expect(box.beginCount == 1)
    #expect(box.endCount == 1)
    #expect(box.live == 0)
    #expect(box.reasons == ["Comparing transcription engines (Second Opinion)"])
}

/// Sleeps in small steps until cancelled — `Task.sleep` throws on cancellation, exactly how the real
/// subprocess clients report it (the `AuxiliaryRunCancellationTests` `RunProbe` shape).
private final class RunProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _started = false
    var started: Bool { lock.withLock { _started } }
    func start() { lock.withLock { _started = true } }
    func runUntilCancelled() async throws {
        start()
        for _ in 0..<5_000 { try await Task.sleep(nanoseconds: 2_000_000) }
    }
}

@MainActor
@Test("A cancelled second opinion still releases the idle-sleep assertion (F560)")
func secondOpinionReleasesActivityOnCancellation() async throws {
    let model = makeModel()
    let box = attachActivityBox(to: model)
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "M", recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed, transcriptText: "hello", segments: [seg("hello", 0, 1)]
    ))
    let probe = RunProbe()
    model.runTranscriptionEngineOverride = { _, _ in
        try await probe.runUntilCancelled()
        return TranscriptionResult(id: "x", text: "hello", languageCode: "en", audioDuration: 1, confidence: nil, segments: [seg("hello", 0, 1)])
    }

    #expect(model.requestSecondOpinion(id: id))
    try await waitUntil("the other engine to start") { probe.started }
    #expect(box.live == 1, "the assertion must be held while the engine runs")
    model.cancelSecondOpinion()
    try await waitUntil("the auxiliary engine to be released") { !model.isRunningAuxiliaryEngine }

    #expect(box.beginCount == 1)
    #expect(box.endCount == 1)
    #expect(box.live == 0)
}

// MARK: - Segment re-run

private let original = [seg("The original first line.", 0, 1), seg("The original second line.", 1, 2)]

/// A completed meeting on a real 16-bit mono WAV, so a segment re-run can slice it (the
/// `AuxiliaryRunCancellationTests` fixture shape — `reTranscribeSegment` reads real audio before the
/// engine seam is ever reached, unlike the other three entry points).
@MainActor
private func makeSegmentRerunModel() throws -> (AppModel, UUID) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F560-SegRerun-\(UUID().uuidString)")
    let id = UUID()
    let directory = root.appendingPathComponent("Recordings/\(id.uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let sampleRate: UInt32 = 16_000
    let bytes = sampleRate * 2 * 2
    var wav = WAVWriter.header(sampleRate: sampleRate, dataByteCount: bytes)
    wav.append(Data(count: Int(bytes)))
    try wav.write(to: directory.appendingPathComponent("meeting.wav"))
    let defaults = UserDefaults(suiteName: testSuiteName())!
    let model = AppModel(
        store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults,
        whisperExecutable: { URL(fileURLWithPath: "/usr/bin/true") }, qwenInstalled: { true }
    )
    model.store.upsert(MeetingRecord(
        id: id, title: "M", duration: 2, recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed, transcriptText: TranscriptFormatter.timestamped(original), segments: original,
        transcriptionEngine: .whisperLarge
    ))
    return (model, id)
}

@MainActor
@Test("A segment re-run releases the idle-sleep assertion on success (F560)")
func segmentRerunReleasesActivityOnSuccess() async throws {
    let (model, id) = try makeSegmentRerunModel()
    let box = attachActivityBox(to: model)
    model.runTranscriptionEngineOverride = { _, _ in
        TranscriptionResult(id: "x", text: "replaced", languageCode: "en", audioDuration: 1, confidence: nil, segments: [seg("replaced", 0, 1)])
    }

    await model.reTranscribeSegment(id: id, index: 0)

    #expect(model.store.meeting(id: id)?.segments.first?.text == "replaced")
    #expect(box.beginCount == 1)
    #expect(box.endCount == 1)
    #expect(box.live == 0)
    #expect(box.reasons == ["Re-transcribing a segment"])
}

// MARK: - Speaker analysis

/// A 16 kHz mono 16-bit WAV of silence — the format speaker analysis prepares. The seam is fully
/// overridden below, so its content never matters; only its path needs to exist for the meeting record.
@MainActor
private func makeDiarizationModel() throws -> (AppModel, UUID) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F560-Diarization-\(UUID().uuidString)")
    let id = UUID()
    let directory = root.appendingPathComponent("Recordings/\(id.uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let sampleRate: UInt32 = 16_000
    var wav = WAVWriter.header(sampleRate: sampleRate, dataByteCount: sampleRate * 2 * 4)
    wav.append(Data(count: Int(sampleRate) * 2 * 4))
    try wav.write(to: directory.appendingPathComponent("meeting.wav"))
    let defaults = UserDefaults(suiteName: testSuiteName())!
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    model.isDiarizationModelInstalled = { true }
    let segments = [seg("one", 0, 2), seg("two", 2, 4)]
    model.store.upsert(MeetingRecord(
        id: id, title: "M", duration: 4, recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed, transcriptText: TranscriptFormatter.timestamped(segments), segments: segments
    ))
    return (model, id)
}

private func twoClusterResult() -> SpeakerDiarizationResult {
    SpeakerDiarizationResult(
        turns: [
            SpeakerTurn(startSeconds: 0, endSeconds: 2, clusterID: 0, kind: .speech),
            SpeakerTurn(startSeconds: 2, endSeconds: 4, clusterID: 1, kind: .speech)
        ],
        speakerCount: 2,
        audioSeconds: 4
    )
}

@MainActor
@Test("Speaker analysis releases the idle-sleep assertion on success (F560)")
func speakerAnalysisReleasesActivityOnSuccess() async throws {
    let (model, id) = try makeDiarizationModel()
    let box = attachActivityBox(to: model)
    model.runSpeakerDiarization = { _, _ in twoClusterResult() }

    model.requestSpeakerDiarization(for: id)
    try await waitUntil("the analysis to finish") { model.diarizationRunningID == nil }

    #expect(box.beginCount == 1)
    #expect(box.endCount == 1)
    #expect(box.live == 0)
    #expect(box.reasons == ["Analyzing speaker turns"])
}

@MainActor
@Test("A cancelled speaker analysis still releases the idle-sleep assertion (F560)")
func speakerAnalysisReleasesActivityOnCancellation() async throws {
    let (model, id) = try makeDiarizationModel()
    let box = attachActivityBox(to: model)
    let probe = RunProbe()
    model.runSpeakerDiarization = { _, _ in
        try await probe.runUntilCancelled()
        return twoClusterResult()
    }

    model.requestSpeakerDiarization(for: id)
    try await waitUntil("the analysis to start") { probe.started }
    #expect(box.live == 1, "the assertion must be held while the analysis runs")
    model.cancelSpeakerDiarization()
    try await waitUntil("the analysis to be released") { model.diarizationRunningID == nil }

    #expect(box.beginCount == 1)
    #expect(box.endCount == 1)
    #expect(box.live == 0)
}
