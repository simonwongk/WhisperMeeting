import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F216/F219 — the FluidAudio adapter that replaces the sherpa-onnx subprocess client. These are
// genuinely red before the adapter exists: `FluidAudioDiarizationClient` is not a type in the
// `WhisperMeet` target, so this file does not compile against the current tree.
//
// Every assertion is about the contract the AppModel seam depends on and NOT about FluidAudio:
// dense first-appearance cluster ids, sorted-and-validated turns, a cancellation that really
// throws, and a failed model load that leaves the staged models on disk (the `prepareModels()`
// landmine — it purges the whole repo on any load failure, which strands an offline machine).

private final class RunnerBox: @unchecked Sendable {
    var started = false
    var release = false
    var ignoredCancellation = false
    var audioURL: URL?
}

private func fluidSegment(
    _ speakerID: String, _ start: TimeInterval, _ end: TimeInterval
) -> FluidAudioDiarizationClient.Segment {
    FluidAudioDiarizationClient.Segment(speakerID: speakerID, startSeconds: start, endSeconds: end)
}

/// An adapter whose runtime stage is a stub. The models directory is deliberately a path that does
/// not exist: nothing below it may be touched when a runner is injected.
private func stubbedClient(
    returning segments: [FluidAudioDiarizationClient.Segment]
) -> FluidAudioDiarizationClient {
    FluidAudioDiarizationClient(
        modelsParentDirectory: URL(fileURLWithPath: "/nonexistent-fluidaudio-models"),
        run: { _, _ in segments }
    )
}

private func temporaryDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test("FluidAudio's cluster ids are remapped to dense 0..<n in first-appearance order (F216)")
func fluidAudioAdapterDensifiesClusterIDsInFirstAppearanceOrder() async throws {
    // FluidAudio numbers clusters "S1", "S2", … and the numbering is neither dense nor ordered by
    // when a voice is first heard: a three-speaker file really does return S2 first.
    let client = stubbedClient(returning: [
        fluidSegment("S2", 0, 2),
        fluidSegment("S5", 2, 4),
        fluidSegment("S2", 4, 6),
        fluidSegment("S9", 6, 8)
    ])

    let result = try await client.diarize(audioURL: URL(fileURLWithPath: "/tmp/a.wav"), durationSeconds: 8)

    #expect(result.turns.map(\.clusterID) == [0, 1, 0, 2])
    #expect(result.speakerCount == 3)
    #expect(result.turns.allSatisfy { $0.kind == .speech })
    #expect(result.audioSeconds == 8)
}

@Test("Turns are sorted before validation, so 'Speaker 1' is the first voice heard (F216)")
func fluidAudioAdapterSortsTurnsBeforeValidating() async throws {
    // `SpeakerTurns.validate` rejects unsorted turns outright, and FluidAudio promises no order.
    let client = stubbedClient(returning: [
        fluidSegment("S7", 4, 6),
        fluidSegment("S3", 0, 2)
    ])

    let result = try await client.diarize(audioURL: URL(fileURLWithPath: "/tmp/a.wav"), durationSeconds: 8)

    #expect(result.turns.map(\.startSeconds) == [0, 4])
    // S3 speaks first once sorted, so S3 — not S7 — is cluster 0.
    #expect(result.turns.map(\.clusterID) == [0, 1])
}

@Test("A turn past the end of the recording fails validation and nothing is returned (F216)")
func fluidAudioAdapterRefusesTurnsPastTheRecordingDuration() async throws {
    let client = stubbedClient(returning: [fluidSegment("S1", 0, 2), fluidSegment("S2", 2, 99)])

    await #expect(throws: LocalDiarizationError.self) {
        _ = try await client.diarize(audioURL: URL(fileURLWithPath: "/tmp/a.wav"), durationSeconds: 8)
    }
}

@Test("Cancelling mid-run throws CancellationError when the runtime honours cancellation (F216)")
func fluidAudioAdapterThrowsCancellationErrorWhenTheRunnerHonoursCancellation() async throws {
    let box = RunnerBox()
    let client = FluidAudioDiarizationClient(
        modelsParentDirectory: URL(fileURLWithPath: "/nonexistent-fluidaudio-models"),
        run: { _, _ in
            box.started = true
            for _ in 0..<200_000 {
                try Task.checkCancellation()
                await Task.yield()
            }
            box.ignoredCancellation = true
            return [fluidSegment("S1", 0, 2)]
        }
    )

    let task = Task { try await client.diarize(audioURL: URL(fileURLWithPath: "/tmp/a.wav"), durationSeconds: 8) }
    while !box.started { await Task.yield() }
    task.cancel()

    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(box.ignoredCancellation == false)
}

@Test("Cancelling mid-run throws CancellationError even if the runtime ignores it (F216)")
func fluidAudioAdapterThrowsCancellationErrorEvenWhenTheRunnerIgnoresIt() async throws {
    // FluidAudio only gained worker-cancellation propagation on 2026-09-03 (PR #886). The adapter
    // does not take that on faith: a cooperative check at its own boundary means a runtime that
    // runs to completion still ends as a cancellation, so no sidecar is ever written for a run the
    // user stopped.
    let box = RunnerBox()
    let client = FluidAudioDiarizationClient(
        modelsParentDirectory: URL(fileURLWithPath: "/nonexistent-fluidaudio-models"),
        run: { _, _ in
            box.started = true
            while !box.release { await Task.yield() }
            box.ignoredCancellation = true
            return [fluidSegment("S1", 0, 2)]
        }
    )

    let task = Task { try await client.diarize(audioURL: URL(fileURLWithPath: "/tmp/a.wav"), durationSeconds: 8) }
    while !box.started { await Task.yield() }
    task.cancel()
    box.release = true

    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(box.ignoredCancellation == true)   // the runtime really did run to completion
}

@Test("The runtime's chunk progress reaches the caller while it runs (F216)")
func fluidAudioAdapterReportsProgressWhileItRuns() async throws {
    let observed = ProgressCollector()
    let client = FluidAudioDiarizationClient(
        modelsParentDirectory: URL(fileURLWithPath: "/nonexistent-fluidaudio-models"),
        run: { _, report in
            report(0.5)
            return [fluidSegment("S1", 0, 2)]
        }
    )

    _ = try await client.diarize(
        audioURL: URL(fileURLWithPath: "/tmp/a.wav"),
        durationSeconds: 8,
        progress: { await observed.append($0) }
    )

    #expect(await observed.values == [0.5])
}

private actor ProgressCollector {
    var values: [Double] = []
    func append(_ value: Double) { values.append(value) }
}

@Test("An uninstalled runtime is reported before any model loader is touched (F216)")
func fluidAudioAdapterReportsAnUninstalledRuntimeBeforeTouchingTheLoader() async throws {
    let parent = try temporaryDirectory("FluidAudioMissing")
    defer { try? FileManager.default.removeItem(at: parent) }
    let client = FluidAudioDiarizationClient(modelsParentDirectory: parent)

    await #expect(throws: LocalDiarizationError.runtimeNotInstalled) {
        _ = try await client.diarize(audioURL: URL(fileURLWithPath: "/tmp/a.wav"), durationSeconds: 8)
    }
}

@Test("The staged model directory is named speaker-diarization, not the Hugging Face repo (F216)")
func fluidAudioAdapterStagesModelsUnderTheFolderNameFluidAudioResolves() {
    // `Repo.diarizer.name` is "FluidInference/speaker-diarization-coreml" but `folderName` strips
    // the "-coreml" suffix, and `ModelHub` resolves <parent>/<folderName>. Staging into a directory
    // named after the repo fails with `DownloadError.modelMissing(repo: "speaker-diarization", …)`
    // — an error that names the folder, not the repo, and so misdirects. Verified during F216.
    #expect(FluidAudioDiarizationRuntime.modelsDirectory().lastPathComponent == "speaker-diarization")
    #expect(
        FluidAudioDiarizationRuntime.modelsDirectory().deletingLastPathComponent()
            == FluidAudioDiarizationRuntime.modelsParentDirectory()
    )
}

@Test("A failed model load leaves every staged model file on disk (F216)")
func fluidAudioAdapterKeepsStagedModelsAfterAFailedLoad() async throws {
    // The reason `prepareModels()` is banned: on ANY load failure it calls `purgeDiarizerRepo`,
    // deleting the staged models and stranding a machine that cannot re-download them. This runs
    // the REAL loader over deliberately damaged bundles and proves the files survive.
    let parent = try temporaryDirectory("FluidAudioDamaged")
    defer { try? FileManager.default.removeItem(at: parent) }
    let models = parent.appendingPathComponent("speaker-diarization", isDirectory: true)
    // Every pinned file present so the tree passes `isInstalled`, and every one of them garbage so
    // the LOADER is what fails. A tree that fails the install probe would stop at
    // `runtimeNotInstalled` and never reach the purge path this test is about.
    for name in FluidAudioDiarizationRuntime.requiredModelFiles {
        let url = models.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not a compiled model".utf8).write(to: url)
    }
    // A REAL readable recording, so the run reaches the model loader rather than stopping at the
    // audio pre-check — the point of this test is what the loader's failure path does.
    let audio = parent.appendingPathComponent("analysis.wav")
    try writeSilentAnalysisWav(seconds: 4, to: audio)
    let client = FluidAudioDiarizationClient(modelsParentDirectory: parent)

    await #expect(throws: LocalDiarizationError.self) {
        _ = try await client.diarize(audioURL: audio, durationSeconds: 4)
    }

    for name in FluidAudioDiarizationRuntime.requiredModelFiles {
        #expect(
            FileManager.default.fileExists(atPath: models.appendingPathComponent(name).path),
            "\(name) was deleted by a failed load"
        )
    }
}

// MARK: - Through the app-level call (AGENTS.md "wiring an unreachable core")

/// A 16 kHz mono 16-bit WAV of silence — the format speaker analysis prepares, so the fixture needs
/// no transcode even when the real seam runs.
private func writeSilentAnalysisWav(seconds: Double, to url: URL) throws {
    let sampleRate: UInt32 = 16_000
    let dataBytes = UInt32(seconds * Double(sampleRate)) * 2
    var wav = WAVWriter.header(sampleRate: sampleRate, dataByteCount: dataBytes)
    wav.append(Data(count: Int(dataBytes)))
    try wav.write(to: url)
}

@MainActor
private struct WiringFixture {
    let model: AppModel
    let id: UUID
    let root: URL
    let wavURL: URL
    var sidecarURL: URL { DiarizationArtifactStore.fileURL(meetingID: id, in: root) }
}

@MainActor
private func makeWiringFixture() throws -> WiringFixture {
    let root = try temporaryDirectory("FluidAudioWiring")
    let id = UUID()
    let directory = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let wavURL = directory.appendingPathComponent("meeting.wav")
    try writeSilentAnalysisWav(seconds: 4, to: wavURL)
    let segments = [
        TranscriptSegment(speaker: nil, start: 0, end: 2, text: "one"),
        TranscriptSegment(speaker: nil, start: 2, end: 4, text: "two")
    ]
    let defaults = UserDefaults(suiteName: "F216.\(UUID().uuidString)")!
    let model = AppModel(
        store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults
    )
    model.isDiarizationModelInstalled = { true }
    model.store.upsert(MeetingRecord(
        id: id, title: "M", duration: 4,
        recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed,
        transcriptText: TranscriptFormatter.timestamped(segments),
        segments: segments
    ))
    return WiringFixture(model: model, id: id, root: root, wavURL: wavURL)
}

@MainActor
@Test("A finished analysis records the FluidAudio runtime in the sidecar's provenance (F216)")
func diarizationSidecarNamesTheFluidAudioRuntime() async throws {
    let fixture = try makeWiringFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    fixture.model.runSpeakerDiarization = { request, _ in
        SpeakerDiarizationResult(
            turns: FluidAudioDiarizationClient.densify([
                fluidSegment("S1", 0, 2), fluidSegment("S2", 2, 4)
            ]),
            speakerCount: 2,
            audioSeconds: request.durationSeconds
        )
    }

    fixture.model.requestSpeakerDiarization(for: fixture.id)
    var ticks = 0
    while fixture.model.diarizationRunningID != nil, ticks < 200_000 { await Task.yield(); ticks += 1 }

    guard case let .ready(artifact) = DiarizationArtifactStore.load(
        meetingID: fixture.id, in: fixture.root
    ) else {
        Issue.record("no sidecar was written")
        return
    }
    // A sidecar that still claimed sherpa-onnx produced these turns would make the runtime swap
    // invisible in results a user already has — the exact thing this field exists to prevent.
    #expect(artifact.producer.runtimeID == "fluidaudio-offline-diarizer")
    #expect(artifact.producer.runtimeVersion == "0.15.7")
    #expect(artifact.producer.clusterThreshold == FluidAudioDiarizationRuntime.clusterThreshold)
}

@MainActor
@Test("Cancelling a run through the FluidAudio adapter writes no sidecar (F216/F219)")
func cancellingTheFluidAudioAdapterThroughAppModelWritesNoSidecar() async throws {
    let fixture = try makeWiringFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = fixture.model
    let id = fixture.id
    let root = fixture.root
    let wavURL = fixture.wavURL

    // The REAL adapter, with only its runtime stage stubbed: the cancellation path under test is
    // the adapter's, not a closure written by the test.
    let box = RunnerBox()
    let client = FluidAudioDiarizationClient(
        modelsParentDirectory: URL(fileURLWithPath: "/nonexistent-fluidaudio-models"),
        run: { url, _ in
            box.audioURL = url
            box.started = true
            for _ in 0..<200_000 {
                try Task.checkCancellation()
                await Task.yield()
            }
            box.ignoredCancellation = true
            return [fluidSegment("S1", 0, 2), fluidSegment("S2", 2, 4)]
        }
    )
    model.runSpeakerDiarization = { request, progress in
        try await client.diarize(
            audioURL: request.audioURL,
            durationSeconds: request.durationSeconds,
            progress: progress
        )
    }
    let wavBefore = try Data(contentsOf: wavURL)
    let transcriptBefore = try #require(model.store.meeting(id: id)?.transcriptText)

    model.requestSpeakerDiarization(for: id)
    var ticks = 0
    while !box.started, ticks < 200_000 { await Task.yield(); ticks += 1 }
    #expect(box.started)
    model.cancelSpeakerDiarization()
    ticks = 0
    while model.diarizationRunningID != nil, ticks < 200_000 { await Task.yield(); ticks += 1 }

    #expect(box.ignoredCancellation == false)
    let sidecar = DiarizationArtifactStore.fileURL(meetingID: id, in: root)
    #expect(!FileManager.default.fileExists(atPath: sidecar.path))
    #expect(model.speakerOverlay(for: id) == nil)
    #expect(model.alertMessage == nil)              // a cancel is not an error
    #expect(try Data(contentsOf: wavURL) == wavBefore)
    #expect(model.store.meeting(id: id)?.transcriptText == transcriptBefore)
}

// MARK: - Real installed models (opt-in)

private let realModelsDirectory = ProcessInfo.processInfo.environment["WHISPERMEET_FLUIDAUDIO_MODELS"]
private let realAudioPath = ProcessInfo.processInfo.environment["WHISPERMEET_FLUIDAUDIO_WAV"]
private let realModelsAvailable = realModelsDirectory != nil && realAudioPath != nil

@Test(
    "The real staged models produce dense, validated turns (F216)",
    .enabled(if: realModelsAvailable)
)
func fluidAudioAdapterRunsAgainstTheRealStagedModels() async throws {
    let client = FluidAudioDiarizationClient(
        modelsParentDirectory: URL(fileURLWithPath: try #require(realModelsDirectory))
    )
    let audio = URL(fileURLWithPath: try #require(realAudioPath))
    let seconds = AppModel.analysisSeconds(of: audio, fallback: 0)
    #expect(seconds > 0)

    let result = try await client.diarize(audioURL: audio, durationSeconds: seconds)

    #expect(result.turns.count > 0)
    #expect(result.speakerCount > 0)
    #expect(Set(result.turns.map(\.clusterID)) == Set(0..<result.speakerCount))
    #expect(result.turns.map(\.startSeconds) == result.turns.map(\.startSeconds).sorted())
    print("REAL RUN: turns=\(result.turns.count) speakers=\(result.speakerCount) seconds=\(seconds)")
}

/// Holds the diarization task so the progress handler can cancel the very run reporting to it.
///
/// The handler can fire before `attach` returns — the relay runs concurrently with the runtime — so
/// a cancel that arrives first is remembered rather than dropped on the floor.
private actor RunningAnalysis {
    private var task: Task<SpeakerDiarizationResult, any Error>?
    private var cancelRequested = false

    var reportedProgress: Bool { cancelRequested }

    func attach(_ task: Task<SpeakerDiarizationResult, any Error>) {
        self.task = task
        if cancelRequested { task.cancel() }
    }

    func cancelNow() {
        cancelRequested = true
        task?.cancel()
    }
}

@Test(
    "Cancellation really propagates into FluidAudio's workers (F216/F226)",
    .enabled(if: realModelsAvailable)
)
func fluidAudioAdapterCancellationPropagatesIntoTheRealRuntime() async throws {
    let client = FluidAudioDiarizationClient(
        modelsParentDirectory: URL(fileURLWithPath: try #require(realModelsDirectory))
    )
    let audio = URL(fileURLWithPath: try #require(realAudioPath))
    let seconds = AppModel.analysisSeconds(of: audio, fallback: 0)

    // Cancel on the runtime's FIRST progress report rather than after a fixed sleep. The sleep this
    // replaced only proved anything if the run was still in flight when it expired: pointed at
    // `Scripts/bench/clips/en1.wav` (3.1 s) the whole analysis finishes in 0.28 s, so the cancel
    // landed after the result and the test failed having caught no defect — an hour of chasing a
    // non-bug for whoever set the env vars to the obvious thing (F226). FluidAudio reports progress
    // from inside its segmentation loop, so the first fraction is mid-run at any length.
    let running = RunningAnalysis()
    let started = Date()
    let task = Task {
        try await client.diarize(audioURL: audio, durationSeconds: seconds) { _ in
            await running.cancelNow()
        }
    }
    await running.attach(task)

    var thrown: (any Error)?
    do { _ = try await task.value } catch { thrown = error }

    // Reported separately so the two ways this can fail read differently. A runtime that never
    // reports progress leaves the cancel unarmed, which is a fact about the fixture; a run that
    // ignores an armed cancel is the regression this test exists to catch.
    #expect(
        await running.reportedProgress,
        "the runtime reported no progress for this file, so no cancel was ever delivered"
    )
    #expect(
        thrown is CancellationError,
        "expected CancellationError, got \(String(describing: thrown))"
    )
    print("REAL CANCEL: returned after \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
}

@Test("The duration turns are validated against survives afconvert's filler chunk (F224)")
func analysisSecondsMeasuresAConvertedRecordingCorrectly() throws {
    // `AppModel.runSpeakerDiarization` converts a 48 kHz meeting to 16 kHz mono with afconvert, and
    // afconvert pads the header with a 4 KB `FLLR` chunk. Read at a fixed offset, that filler's size
    // became the audio length: a half-hour recording measured 0.13 s, so every turn "exceeded" it
    // and `SpeakerTurns.validate` threw away the entire analysis. This is that bound, measured the
    // way the real run measures it.
    let directory = try temporaryDirectory("AnalysisSeconds")
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("meeting.wav")
    var wav = WAVWriter.header(sampleRate: 48_000, dataByteCount: 48_000 * 2 * 10)
    wav.append(Data(count: 48_000 * 2 * 10))
    try wav.write(to: source)
    #expect(AudioTranscoder.needsTranscoding(source))      // a real meeting always converts

    let converted = directory.appendingPathComponent("analysis.wav")
    try AudioTranscoder.transcodeToWAV(input: source, output: converted)

    let seconds = AppModel.analysisSeconds(of: converted, fallback: -1)
    #expect(abs(seconds - 10) < 0.05, "measured \(seconds)s for a 10-second recording")
}

// F216/F219 — silence is a RESULT, not a failure. The predecessor test for this ran unconditionally;
// its successor is gated on real models being staged, so on an ordinary machine nothing covers it.
// The path needs no models at all — the adapter takes an injectable runner — and a regression that
// made an empty segment list throw would turn a muted-microphone meeting into a red "Speaker
// analysis did not finish" alert with no test to catch it.

@Test("A runtime that reports no segments yields an empty result, not a failure (F216/F219)")
func fluidAudioAdapterTreatsNoSegmentsAsAnEmptyResult() async throws {
    let client = FluidAudioDiarizationClient(run: { _, _ in [] })
    let result = try await client.diarize(
        audioURL: URL(fileURLWithPath: "/tmp/does-not-need-to-exist.wav"),
        durationSeconds: 1,
        progress: { _ in }
    )
    #expect(result.turns.isEmpty)
    #expect(result.speakerCount == 0)
}
