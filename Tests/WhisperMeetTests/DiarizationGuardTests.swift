import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F219 — admission guards for speaker analysis. Genuinely red without the wiring: there is no
// `requestSpeakerDiarization` to refuse anything, and no `runSpeakerDiarization` seam whose call
// counter could prove the refusal happened BEFORE any work started. That ordering is the whole
// point — analysis is minutes of subprocess time whose only product is a sidecar a read-only
// library would refuse, and it must never run on top of a transcription, another engine pass,
// dictation, or a model install (the F187/F140 lesson, applied to a new heavy path).

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

private final class SeamCounter: @unchecked Sendable {
    var calls = 0
}

private func writeSilentWav(seconds: Double, to url: URL) throws {
    let sampleRate: UInt32 = 16_000
    let dataBytes = UInt32(seconds * Double(sampleRate)) * 2
    var wav = WAVWriter.header(sampleRate: sampleRate, dataByteCount: dataBytes)
    wav.append(Data(count: Int(dataBytes)))
    try wav.write(to: url)
}

/// Gives any task the request might have spawned a real chance to reach the seam, so a
/// "the seam was never called" assertion is about the guard rather than about scheduling luck.
@MainActor
private func settle() async {
    for _ in 0..<50 { await Task.yield() }
}

@MainActor
private struct GuardFixture {
    let model: AppModel
    let id: UUID
    let root: URL
    let counter = SeamCounter()
}

/// Seeds a writable library with one completed, natively recorded meeting, then installs a seam that
/// only counts calls. `degraded` reproduces the field's real read-only state (`.recoveredFromBackup`)
/// the way `DegradedLibraryTests` does: seed with a healthy store, then corrupt only the primary so
/// the reopened store carries records AND refuses mutation.
@MainActor
private func makeGuardFixture(
    status: MeetingStatus = .completed,
    segments: [TranscriptSegment] = [seg("one", 0, 2), seg("two", 2, 4)],
    recordingFileName: String = "meeting.wav",
    source: MediaSource? = nil,
    degraded: Bool = false
) throws -> GuardFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiarizationGuard-\(UUID().uuidString)", isDirectory: true)
    let id = UUID()
    let directory = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try writeSilentWav(seconds: 4, to: directory.appendingPathComponent(recordingFileName))

    let record = MeetingRecord(
        id: id, title: "M", duration: 4,
        recordingPath: "Recordings/\(id.uuidString)/\(recordingFileName)",
        status: status,
        transcriptText: TranscriptFormatter.timestamped(segments),
        segments: segments,
        source: source
    )
    let seed = MeetingStore(rootDirectory: root)
    seed.upsert(record)
    try #require(!seed.isDegraded, "the seed store must be writable, or nothing was persisted")
    if degraded {
        try Data("truncated-primary".utf8).write(to: root.appendingPathComponent("meetings.json"))
    }

    let defaults = UserDefaults(suiteName: "F219guard.\(UUID().uuidString)")!
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    model.isDiarizationModelInstalled = { true }
    let fixture = GuardFixture(model: model, id: id, root: root)
    let counter = fixture.counter
    model.runSpeakerDiarization = { _, _ in
        counter.calls += 1
        return SpeakerDiarizationResult(turns: [], speakerCount: 0, audioSeconds: 4)
    }
    if degraded {
        try #require(model.store.isDegraded, "the reopened store must be read-only")
    }
    return fixture
}

@MainActor
@Test("Speaker analysis refuses to start a second run on top of a running one (F219)")
func diarizationRefusesWhileAlreadyRunning() async throws {
    let fixture = try makeGuardFixture()
    let counter = fixture.counter
    let gate = SeamCounter()
    fixture.model.runSpeakerDiarization = { _, _ in
        counter.calls += 1
        while gate.calls == 0 { await Task.yield() }
        return SpeakerDiarizationResult(turns: [], speakerCount: 0, audioSeconds: 4)
    }
    fixture.model.requestSpeakerDiarization(for: fixture.id)
    var ticks = 0
    while counter.calls == 0, ticks < 200_000 { await Task.yield(); ticks += 1 }
    #expect(counter.calls == 1)

    fixture.model.requestSpeakerDiarization(for: fixture.id)
    await settle()

    #expect(counter.calls == 1)                                   // the second request started nothing
    #expect(fixture.model.alertMessage?.contains("already") == true)
    gate.calls = 1
    ticks = 0
    while fixture.model.diarizationRunningID != nil, ticks < 200_000 { await Task.yield(); ticks += 1 }
}

@MainActor
@Test("Speaker analysis refuses while a meeting transcription is running (F219)")
func diarizationRefusesDuringTranscription() async throws {
    let fixture = try makeGuardFixture()
    let other = UUID()
    fixture.model.store.upsert(MeetingRecord(id: other, title: "B", status: .recorded))
    // A stubbed engine and a stubbed runtime probe: the transcription Task is scheduled but cannot run
    // until this synchronous stretch suspends, so the queue stays active across the request below.
    fixture.model.findWhisperExecutable = { URL(fileURLWithPath: "/usr/bin/true") }
    fixture.model.runTranscriptionEngineOverride = { _, _ in
        TranscriptionResult(id: "x", text: "hi", languageCode: "en", audioDuration: 1, confidence: nil, segments: [])
    }
    fixture.model.beginTranscription(id: other)
    try #require(fixture.model.hasActiveTranscription, "the transcription queue must be active")
    fixture.model.alertMessage = nil

    fixture.model.requestSpeakerDiarization(for: fixture.id)
    #expect(fixture.model.diarizationRunningID == nil)
    #expect(fixture.model.alertMessage?.contains("transcription") == true)
    await settle()
    #expect(fixture.counter.calls == 0)
}

@MainActor
@Test("Speaker analysis refuses while another engine pass is running (F219)")
func diarizationRefusesDuringAuxiliaryEngineRun() async throws {
    let fixture = try makeGuardFixture()
    fixture.model.runTranscriptionEngineOverride = { _, _ in
        TranscriptionResult(id: "x", text: "one two", languageCode: "en", audioDuration: 4, confidence: nil, segments: [])
    }
    fixture.model.requestSecondOpinion(id: fixture.id)
    try #require(fixture.model.isRunningAuxiliaryEngine, "the auxiliary engine flag must be claimed")

    fixture.model.requestSpeakerDiarization(for: fixture.id)
    #expect(fixture.model.diarizationRunningID == nil)
    #expect(fixture.model.alertMessage != nil)
    await settle()
    #expect(fixture.counter.calls == 0)
    var ticks = 0
    while fixture.model.isRunningAuxiliaryEngine, ticks < 200_000 { await Task.yield(); ticks += 1 }
}

@MainActor
@Test("Speaker analysis refuses while Quick Dictation owns the microphone (F219)")
func diarizationRefusesDuringDictation() async throws {
    let fixture = try makeGuardFixture()
    fixture.model.configureDictationGuard { true }

    fixture.model.requestSpeakerDiarization(for: fixture.id)
    await settle()

    #expect(fixture.counter.calls == 0)
    #expect(fixture.model.diarizationRunningID == nil)
    #expect(fixture.model.alertMessage?.contains("Dictation") == true)
}

@MainActor
@Test("Speaker analysis refuses while the library is read-only (F219)")
func diarizationRefusesWhileLibraryIsReadOnly() async throws {
    let fixture = try makeGuardFixture(degraded: true)

    fixture.model.requestSpeakerDiarization(for: fixture.id)
    await settle()

    #expect(fixture.counter.calls == 0)   // minutes of analysis are never spent on a refused save
    #expect(fixture.model.diarizationRunningID == nil)
    #expect(fixture.model.alertMessage?.isEmpty == false)
    #expect(!FileManager.default.fileExists(
        atPath: DiarizationArtifactStore.fileURL(meetingID: fixture.id, in: fixture.root).path
    ))
}

@MainActor
@Test("Speaker analysis offers the install instead of running without a model (F219)")
func diarizationRefusesWhenTheModelIsNotInstalled() async throws {
    let fixture = try makeGuardFixture()
    fixture.model.isDiarizationModelInstalled = { false }

    fixture.model.requestSpeakerDiarization(for: fixture.id)
    await settle()

    #expect(fixture.counter.calls == 0)
    #expect(fixture.model.alertMessage?.contains("not installed") == true)
}

@MainActor
@Test("Speaker analysis refuses a transcript with no usable timings (F219)")
func diarizationRefusesWithoutUsableTimings() async throws {
    // The Qwen alignment-failure shape: complete text, no timestamps to reconcile against.
    let fixture = try makeGuardFixture(segments: [TranscriptSegment(speaker: nil, start: nil, end: nil, text: "one two")])

    fixture.model.requestSpeakerDiarization(for: fixture.id)
    await settle()

    #expect(fixture.counter.calls == 0)
    #expect(fixture.model.alertMessage?.contains("timestamp") == true)
}

@MainActor
@Test("Speaker analysis refuses a meeting that is not a completed native recording (F219)")
func diarizationRefusesNonNativeOrUnfinishedMeetings() async throws {
    let unfinished = try makeGuardFixture(status: .recorded)
    unfinished.model.requestSpeakerDiarization(for: unfinished.id)
    await settle()
    #expect(unfinished.counter.calls == 0)
    #expect(unfinished.model.alertMessage != nil)

    // A link import is excluded in v1: its source quality and recovery path have their own gate.
    let imported = try makeGuardFixture(
        recordingFileName: "downloaded.m4a",
        source: MediaSource(kind: MediaSource.youTubeKind, pageURL: "https://example.com/v", host: "example.com", fetchedAt: Date())
    )
    imported.model.requestSpeakerDiarization(for: imported.id)
    await settle()
    #expect(imported.counter.calls == 0)
    #expect(imported.model.alertMessage != nil)
}

/// F219 — the systematic backstop. `requestSpeakerDiarization` is the guard the user should normally
/// hit, because it names the action attempted; this one exists for the caller that reaches the worker
/// directly. `DiarizationArtifactStore` holds no `MeetingStore` reference by design, so nothing below
/// AppModel would otherwise refuse to write a sidecar into a read-only library (the F187 lesson).
@MainActor
@Test("The speaker-analysis worker refuses a read-only library on its own (F219)")
func diarizationWorkerRefusesReadOnlyLibraryDirectly() async throws {
    let fixture = try makeGuardFixture(degraded: true)
    let meeting = try #require(fixture.model.store.meeting(id: fixture.id))

    await fixture.model.performSpeakerDiarization(SpeakerDiarizationRequest(
        meetingID: fixture.id,
        audioURL: fixture.model.store.recordingURL(for: meeting),
        durationSeconds: 4
    ))

    #expect(fixture.counter.calls == 0)
    #expect(!FileManager.default.fileExists(
        atPath: DiarizationArtifactStore.fileURL(meetingID: fixture.id, in: fixture.root).path
    ))
}
