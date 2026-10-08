import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

// F823 — Quick Dictation's first-run model download (1.6 GB) was silent: the Dictation tab and the
// menu bar said nothing, a press during it waited for the whole download with no end shown, the
// Dictation tab's "model ready" row on a Mac without the warm helper (Intel) was ✗ forever beside a
// Repair that could not fix it, and a Repair during the download restarted it. Driven through the
// real controller with an engine that reports a download the test controls.

/// An engine whose model download the test starts and finishes. `warmUp` downloads when
/// `downloadsOnWarmUp`; otherwise `transcribe` does, as a press made before the download began finds.
private final class ControlledDownloadEngine: DictationEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var observer: DictationModelDownloadObserver?
    private var released = false
    let downloadsOnWarmUp: Bool

    init(downloadsOnWarmUp: Bool) { self.downloadsOnWarmUp = downloadsOnWarmUp }

    func release() { lock.withLock { released = true } }
    private var isReleased: Bool { lock.withLock { released } }

    func observeModelDownload(_ observer: DictationModelDownloadObserver?) { lock.withLock { self.observer = observer } }

    private func download() async throws {
        lock.withLock { observer }?(true)
        let deadline = ContinuousClock.now + .seconds(30)
        while !isReleased, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        lock.withLock { observer }?(false)
    }

    func warmUp() async throws {
        if downloadsOnWarmUp { try await download() }
    }

    func transcribe(wavAt url: URL, language: WhisperLanguage, initialPrompt: String?) async throws -> DictationResult {
        if !downloadsOnWarmUp { try await download() }
        return DictationResult(text: "hello after the download", languageCode: "en")
    }

    func shutdown() {}
}

@MainActor
private final class PhaseRecordingOverlay: DictationOverlayPresenting {
    private(set) var phases: [DictationOverlay.Phase] = []
    var onCopy: (() -> Void)?
    func show(_ phase: DictationOverlay.Phase) { phases.append(phase) }
    func update(level: Float) {}
    func hide() {}
}

@MainActor
private struct Harness {
    let controller: DictationController
    let monitor = FakeHotkeyMonitor()
    let recorder: FakeDictationRecorder
    let overlay = PhaseRecordingOverlay()
    let engine: ControlledDownloadEngine
    let announcements: AnnouncementLog
    let cleanUp: () -> Void

    init(downloadsOnWarmUp: Bool) throws {
        let suite = testSuiteName()
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationModelDownloadProgress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults.set(true, forKey: "dictationEnabled")
        defaults.set(false, forKey: "dictationAutoPaste")
        let engine = ControlledDownloadEngine(downloadsOnWarmUp: downloadsOnWarmUp)
        self.engine = engine
        recorder = FakeDictationRecorder(outputURL: directory.appendingPathComponent("clip.wav"))
        let announcements = AnnouncementLog()
        self.announcements = announcements
        controller = DictationController(
            defaults: defaults,
            engine: engine,
            recorder: recorder,
            overlay: overlay,
            hotkeyMonitor: monitor,
            logStore: DictationLogStore(directory: directory),
            captureSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            refiner: FakeRefiner(),
            textInjector: isolatedTextInjector(),
            activateOnInit: false
        )
        controller.clipboardNotifier = {}
        controller.announce = { announcements.said.append($0) }
        cleanUp = {
            engine.release()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Polls `condition` under a 30 s cap and requires it.
    func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition(), "timed out waiting for \(what)")
    }
}

@MainActor
private final class AnnouncementLog {
    var said: [String] = []
}

@MainActor
@Test("While the model downloads the controller says so, and a press is refused with the reason before anything is recorded (F823)")
func aPressDuringTheFirstDownloadIsRefusedAndExplained() async throws {
    let harness = try Harness(downloadsOnWarmUp: true)
    defer { harness.cleanUp() }

    harness.controller.warmUpIfNeeded() // enabling, or launch with dictation on
    try await harness.waitUntil("the download to be reported") { harness.controller.isDownloadingModel }

    harness.monitor.onPressStart?()

    #expect(harness.controller.status != .listening)
    #expect(!harness.recorder.isRecording, "the microphone was started for a dictation that would wait for the download")
    #expect(harness.overlay.phases.last == .modelDownloading)
    #expect(harness.announcements.said.last == DictationController.modelDownloadRefusal)
    #expect(harness.monitor.resetToggleCount >= 1, "toggle mode would stay latched on a refused press (F38)")

    harness.engine.release()
    try await harness.waitUntil("the download to end") { !harness.controller.isDownloadingModel }

    harness.monitor.onPressStart?()
    #expect(harness.controller.status == .listening, "a press after the download should dictate")
}

@MainActor
@Test("A dictation already waiting when the download starts shows the download in its pill, then is transcribed (F823)")
func aDictationWaitingOnTheDownloadShowsItAndThenFinishes() async throws {
    let harness = try Harness(downloadsOnWarmUp: false)
    defer { harness.cleanUp() }

    harness.monitor.onPressStart?()
    try #require(harness.controller.status == .listening)
    harness.monitor.onPressEnd?()
    try await harness.waitUntil("the pill to show the download") {
        harness.overlay.phases.contains(.modelDownloading)
    }
    #expect(harness.controller.isDownloadingModel)
    #expect(harness.controller.status == .transcribing)

    harness.engine.release()
    try await harness.waitUntil("the dictation to be delivered") {
        !harness.controller.logStore.log.entries.isEmpty
    }

    #expect(harness.controller.logStore.log.entries.first?.text == "hello after the download")
    let phases = harness.overlay.phases
    let downloading = try #require(phases.firstIndex(of: .modelDownloading))
    let backToTranscribing = try #require(phases.lastIndex(of: .transcribing))
    let delivered = try #require(phases.lastIndex(of: .copied))
    #expect(downloading < backToTranscribing && backToTranscribing < delivered, "\(phases)")
    #expect(!harness.controller.isDownloadingModel)
}

@MainActor
@Test("Without the warm helper (Intel), the Whisper model row is not offered a Repair that cannot fetch it (F823)")
func theModelRowOffersRepairOnlyWhereRepairCanFetchTheModel() throws {
    // The decision, both ways.
    let warm = DictationController.whisperTurboModelState(
        warmHelperRuns: true, mlxModelCached: { false }, checkpointCached: { true }
    )
    #expect(warm.ready == false && warm.repairable == true)
    let batch = DictationController.whisperTurboModelState(
        warmHelperRuns: false, mlxModelCached: { true }, checkpointCached: { false }
    )
    #expect(batch.ready == false && batch.repairable == false)
    #expect(DictationController.whisperTurboModelState(
        warmHelperRuns: false, mlxModelCached: { false }, checkpointCached: { true }
    ).ready)

    // What the row then offers.
    var diagnostics = DictationDiagnostics(
        engineName: "Whisper Turbo", runtimeInstalled: true, helperInstalled: true, modelReady: false,
        modelRepairable: false, microphoneGranted: true, accessibilityGranted: true, hotkeyActive: true
    )
    #expect(!diagnostics.offersRepair, "Repair cannot fetch the batch engine's checkpoint")
    diagnostics.modelRepairable = true
    #expect(diagnostics.offersRepair)
    diagnostics.modelRepairable = false
    diagnostics.runtimeInstalled = false
    #expect(diagnostics.offersRepair, "a missing runtime is still Repair's to fix")

    // And the controller's own diagnostics, on a Mac told it has no warm helper, over a temporary
    // library — never this Mac's.
    let harness = try Harness(downloadsOnWarmUp: false)
    defer { harness.cleanUp() }
    let support = FileManager.default.temporaryDirectory.appendingPathComponent("F823-diag-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: support) }
    harness.controller.warmWhisperHelperRunsHere = false
    let before = harness.controller.diagnostics(applicationSupport: support)
    #expect(before.modelReady == false && before.modelRepairable == false)

    let models = LocalWhisperRuntime.modelDirectory(applicationSupport: support)
    try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
    try Data([0]).write(to: models.appendingPathComponent(LocalWhisperRuntime.checkpointFileName(for: .turbo)))
    #expect(harness.controller.diagnostics(applicationSupport: support).modelReady)

    harness.controller.warmWhisperHelperRunsHere = true
    let appleSilicon = harness.controller.diagnostics(applicationSupport: support)
    #expect(appleSilicon.modelReady == false, "with the warm helper the model is the MLX weights, not the checkpoint")
    #expect(appleSilicon.modelRepairable)
}

@MainActor
@Test("Install / Repair Local Whisper waits while the dictation model downloads, and says why (F823)")
func localWhisperInstallWaitsForTheDictationDownload() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F823-install-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = testSuiteName()
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    try #require(model.installBlockedReason(for: .whisper) == nil, "something else already blocks an install here")

    var downloading = true
    model.configureDictationModelDownload { downloading }

    #expect(model.recognitionRuntimeInstallBlockedReason == "Wait for the Quick Dictation model to finish downloading.")
    #expect(!model.canInstall(.whisper))
    downloading = false
    #expect(model.recognitionRuntimeInstallBlockedReason == nil)
}

@MainActor
@Test("The Dictation tab, the menu bar and the app wiring show the download (F823)")
func theDownloadIsShownWhereTheUserLooks() throws {
    let view = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/DictationView.swift")
    #expect(view.contains("if dictation.isDownloadingModel {"))
    #expect(view.contains("DictationController.modelDownloadNotice"))
    #expect(view.contains("if diag.offersRepair {"))
    #expect(!view.contains("!diag.modelReady {"), "the Repair offer must not ignore whether Repair can fix the model")

    let entry = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppEntry.swift")
    #expect(entry.contains("model.configureDictationModelDownload { dictation.isDownloadingModel }"))
    #expect(entry.contains("if dictation.isDownloadingModel {"), "the menu-bar menu says nothing while the model downloads")
}
