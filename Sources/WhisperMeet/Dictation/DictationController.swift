// Sources/WhisperMeet/Dictation/DictationController.swift
import AppKit
import AVFoundation
import Foundation
import UserNotifications
import WhisperCore
import os

/// Snapshot of the dictation feature's health, gathered on demand for a future diagnostics UI.
struct DictationDiagnostics: Equatable {
    var engineName: String
    var runtimeInstalled: Bool
    var helperInstalled: Bool
    var modelReady: Bool
    var microphoneGranted: Bool
    var accessibilityGranted: Bool
    var hotkeyActive: Bool
}

/// Owns the quick-dictation feature end to end: hotkey → capture → selected local model → paste,
/// driven by the pure `DictationSession`. Independent of the meeting pipeline.
@MainActor
final class DictationController: ObservableObject {
    enum Status: Equatable {
        case disabled, idle, listening, transcribing, delivering
        case error(String)
    }

    @Published private(set) var status: Status = .disabled
    @Published var enabled: Bool { didSet { persist(); apply() } }
    @Published var hotkey: DictationHotkey { didSet { persist(); if enabled { applyHotkeyStart() } } }
    @Published var language: WhisperLanguage { didSet { persist() } }
    @Published var autoPaste: Bool { didSet { persist() } }
    @Published private(set) var selectedEngine: DictationTranscriptionEngine
    /// Whether Quick Dictation feeds the business vocabulary into Whisper's initial prompt. On by
    /// default (same spelling nudge meetings get); can be turned off for plain dictation.
    @Published var useVocabulary: Bool { didSet { persist() } }
    /// F200: opt-in local-AI cleanup of dictated text before delivery. Off by default — the
    /// documented "local-instant feel" stays untouched unless the user chooses the trade.
    @Published var refineEnabled: Bool { didSet { persist(); applyRefineSetting() } }
    /// Injectable so headless tests can simulate runtime presence; the default asks the real
    /// Summarizer runtime. Read directly by the Settings UI on each render.
    var refineRuntimeAvailability: () -> Bool = {
        SummarizerRuntime.isSupportedOnCurrentMac && SummarizerRuntime.isRefineHelperInstalled()
    }
    var isRefineRuntimeInstalled: Bool { refineRuntimeAvailability() }

    var isAccessibilityTrusted: Bool { HotkeyMonitor.isAccessibilityTrusted }
    func requestAccessibility() { HotkeyMonitor.requestAccessibility() }

    /// True while dictation owns the microphone/result path or is retiring a resident model. Used by
    /// `AppModel` to avoid microphone and large-model contention with meeting recording.
    var isActive: Bool {
        if isSwitchingModel || isSelfTesting { return true }
        switch status {
        case .listening, .transcribing, .delivering: return true
        case .disabled, .idle, .error: return false
        }
    }

    let logStore: DictationLogStore
    @Published var selfTestResult: String?
    @Published private(set) var isSelfTesting = false
    @Published private(set) var isSwitchingModel = false

    private let defaults: UserDefaults
    private let hotkeyMonitor: any HotkeyMonitoring
    private let recorder: any DictationRecording
    private let overlay: any DictationOverlayPresenting
    private let engine: SelectableDictationEngine
    private let refiner: any DictationTextRefining
    private let engineFactory: (DictationTranscriptionEngine) -> DictationEngine
    private let captureTimeout: Duration
    private let captureSleep: DictationCaptureWatchdog.Sleep
    private var session = DictationSession()
    private var isMicrophoneBusy: () -> Bool = { false }
    private var isRecognitionRuntimeInstalling: () -> Bool = { false }
    private var isMeetingTranscriptionRunning: () -> Bool = { false }
    private var vocabularyProvider: () -> [String] = { [] }
    private var dismissWorkItem: DispatchWorkItem?
    private var busyHideWorkItem: DispatchWorkItem?
    private var idleEvictWorkItem: DispatchWorkItem?
    private var hotkeyActive = false
    /// Both warm-up tasks are cancellable and generation-guarded. A meeting release must prevent a
    /// task that was queued while idle from launching a model after that meeting has claimed memory.
    private var engineWarmTask: Task<Void, Never>?
    private var engineWarmGeneration = 0
    /// The optional polishing model is deliberately warmed only when it cannot contend with ASR.
    /// A generation invalidates an old asynchronous warm-up after eviction/disable.
    private var refinerWarmTask: Task<Void, Never>?
    private var refinerIsWarm = false
    private var refinerIsWarming = false
    private var refinerWarmGeneration = 0
    /// An asynchronous refiner teardown creates a hard boundary before the next recognition warm-up
    /// or request. It is nil for an already resident refiner, which the user explicitly opted into.
    private var refinerReleaseForCapture: Task<Void, Never>?
    /// A timed-out refine request is still consuming the helper until it naturally finishes. The
    /// next press must evict it before recognition starts, even though the model itself had been
    /// fully warm when the timeout was reported.
    private var refinerRequiresReleaseBeforeRecognition = false
    private let log = Logger(subsystem: "com.whispermeet.app", category: "dictation")
    private lazy var captureWatchdog = DictationCaptureWatchdog(
        timeout: captureTimeout,
        sleep: captureSleep
    ) { [weak self] in
        guard let self, self.enabled, self.status == .listening else { return }
        self.log.notice("maximum dictation capture duration reached; finalizing")
        _ = self.beginTranscriptionIfNeeded()
        // The watchdog finalized without a user end-edge, so toggle mode's latched state must be
        // cleared or the next press fires a no-op end edge instead of a fresh start (F78). No-op in
        // hold mode, which never reads toggledOn.
        self.hotkeyMonitor.resetToggleState()
    }

    private let idleEvictSeconds: TimeInterval // 5 min default; injectable for tests

    private static let enabledKey = "dictationEnabled"
    private static let refineEnabledKey = "dictationRefineEnabled"
    private static let hotkeyKey = "dictationHotkey"
    private static let languageKey = "dictationLanguage"
    private static let autoPasteKey = "dictationAutoPaste"
    private static let useVocabularyKey = "dictationUseVocabulary"
    private static let engineKey = "dictationTranscriptionEngine"

    init(
        defaults: UserDefaults = .standard,
        engine: DictationEngine? = nil,
        engineFactory: ((DictationTranscriptionEngine) -> DictationEngine)? = nil,
        recorder: any DictationRecording = MicDictationRecorder(),
        overlay: (any DictationOverlayPresenting)? = nil,
        hotkeyMonitor: any HotkeyMonitoring = HotkeyMonitor(),
        logStore: DictationLogStore? = nil,
        captureTimeout: Duration = .seconds(DictationCaptureLimits.maximumDurationSeconds),
        captureSleep: @escaping DictationCaptureWatchdog.Sleep = {
            try await Task.sleep(for: $0)
        },
        refiner: (any DictationTextRefining)? = nil,
        idleEvictSeconds: TimeInterval = 300,
        activateOnInit: Bool = true
    ) {
        self.defaults = defaults
        self.recorder = recorder
        self.overlay = overlay ?? DictationOverlay()
        self.hotkeyMonitor = hotkeyMonitor
        self.logStore = logStore ?? DictationLogStore()
        self.captureTimeout = captureTimeout
        self.captureSleep = captureSleep
        self.idleEvictSeconds = idleEvictSeconds
        self.refiner = refiner ?? DictationRefiner(
            engine: WarmRefineEngine(
                python: SummarizerRuntime.pythonExecutable(),
                script: SummarizerRuntime.refineHelperScript(),
                modelDirectory: SummarizerRuntime.modelDirectory(),
                // F203: prime the helper's prompt cache at warm-up with the real base prompt —
                // the language-pinned variants extend it, so their common token prefix stays hot.
                primePrompt: DictationRefinePrompt.system(languageCode: nil)
            )
        )
        let storedEngine = DictationTranscriptionEngine(
            rawValue: defaults.string(forKey: Self.engineKey) ?? ""
        ) ?? .whisperTurbo
        let initialSelection = storedEngine.isSupportedOnCurrentMac ? storedEngine : .whisperTurbo
        selectedEngine = initialSelection
        let factory = engineFactory ?? DictationController.makeEngine
        self.engineFactory = factory
        self.engine = SelectableDictationEngine(
            engine: engine ?? factory(initialSelection)
        )
        enabled = defaults.bool(forKey: Self.enabledKey)
        hotkey = (try? JSONDecoder().decode(DictationHotkey.self, from: defaults.data(forKey: Self.hotkeyKey) ?? Data())) ?? .rightOption
        language = WhisperLanguage(rawValue: defaults.string(forKey: Self.languageKey) ?? "") ?? .automatic
        autoPaste = defaults.object(forKey: Self.autoPasteKey) as? Bool ?? true
        useVocabulary = defaults.object(forKey: Self.useVocabularyKey) as? Bool ?? true
        refineEnabled = defaults.object(forKey: Self.refineEnabledKey) as? Bool ?? false

        hotkeyMonitor.onPressStart = { [weak self] in self?.handlePressStart() }
        hotkeyMonitor.onPressEnd = { [weak self] in self?.handlePressEnd() }
        if activateOnInit {
            ensureHelperInstalled()
            apply()
        }
    }

    private static func makeEngine(for selection: DictationTranscriptionEngine) -> DictationEngine {
        if selection == .qwenBalanced {
            return WarmQwenDictationEngine(
                python: QwenASRRuntime.pythonExecutable(),
                script: QwenASRRuntime.dictationHelperScript(),
                modelDirectory: QwenASRRuntime.modelDirectory()
            )
        }
        let python = LocalWhisperRuntime.pythonExecutable()
        let script = LocalWhisperRuntime.dictationServerScript()
        let models = LocalWhisperRuntime.modelDirectory()
        let warm = WarmWhisperDictationEngine(python: python, script: script, modelDirectory: models)
        // Fall back to the batch openai/whisper CLI when the warm MLX helper can't run (Intel Mac,
        // runtime without MLX, or a broken MLX install) so dictation still works there instead of
        // failing outright. Meetings are unaffected — this only backs Quick Dictation.
        let whisperExecutable = LocalWhisperRuntime.findExecutable() ?? LocalWhisperRuntime.managedExecutable()
        let batch = BatchWhisperDictationEngine(
            client: LocalWhisperClient(executableURL: whisperExecutable, modelDirectory: models),
            model: .turbo
        )
        return FallbackDictationEngine(primary: warm, fallback: batch)
    }

    func configure(isMicrophoneBusy: @escaping () -> Bool) {
        self.isMicrophoneBusy = isMicrophoneBusy
    }

    /// Dictation is intentionally paused while a *meeting* recognition runtime is installing: a
    /// multi-GB download + model load contends for CPU and memory, so a warm dictation would stutter.
    /// This is a distinct reason from "microphone busy" — kept separate so logs/diagnostics are
    /// accurate rather than claiming a microphone conflict (F37).
    func configureRuntimeInstalling(_ provider: @escaping () -> Bool) {
        self.isRecognitionRuntimeInstalling = provider
    }

    /// Prevent a new local ASR job from competing with a post-meeting engine. This is a distinct
    /// resource boundary from the microphone and installer guards: both workloads use unified
    /// memory even though neither needs the microphone.
    func configureMeetingTranscriptionRunning(_ provider: @escaping () -> Bool) {
        isMeetingTranscriptionRunning = provider
    }

    /// Releases only idle models before a meeting engine begins. Waiting for the children to exit
    /// is load-bearing: a fire-and-forget shutdown still let a 4B/8B refiner contend with Qwen's
    /// ASR and aligner during their startup.
    func releaseIdleModelsForMeetingTranscription() async {
        guard !isActive else { return }
        let pendingRefinerRelease = refinerReleaseForCapture
        idleEvictWorkItem?.cancel()
        invalidateEngineWarmth()
        invalidateRefinerWarmth()
        refinerRequiresReleaseBeforeRecognition = false
        refinerReleaseForCapture = nil
        await engine.evict()
        if let pendingRefinerRelease {
            await pendingRefinerRelease.value
        } else {
            await refiner.evict()
        }
        log.notice("released idle dictation models before meeting transcription")
    }

    /// Supplies the business vocabulary (same source meetings already feed into their
    /// `initial_prompt`) so Quick Dictation gets the same spelling nudge for proper nouns/jargon.
    func configureVocabulary(_ provider: @escaping () -> [String]) {
        self.vocabularyProvider = provider
    }

    func setEnabled(_ on: Bool) { enabled = on }

    func setSelectedEngine(_ selection: DictationTranscriptionEngine) {
        guard selection.isSupportedOnCurrentMac,
              selection != selectedEngine,
              !isActive,
              !isSelfTesting else { return }
        idleEvictWorkItem?.cancel()
        invalidateEngineWarmth()
        selectedEngine = selection
        persist()
        ensureHelperInstalled()
        let replacement = engineFactory(selection)
        isSwitchingModel = true
        selfTestResult = nil
        log.notice("dictation model changed to \(selection.rawValue, privacy: .public)")
        Task { [engine] in
            await engine.replace(with: replacement)
            self.isSwitchingModel = false
            self.warmUpIfNeeded()
        }
    }

    private func applyRefineSetting() {
        if refineEnabled {
            prewarmRefinerWhenSafe()
        } else {
            // Do not let a setting change leave a terminating 4B/8B helper racing the next
            // recognition warm-up. The boundary is asynchronous because `didSet` is synchronous.
            beginRefinerRelease()
        }
    }

    private func prewarmEngineForCapture() {
        // F202: without this, a dictation after idle eviction pays the full subprocess spawn +
        // model load entirely after key release. This overlaps the reload with the user's speaking
        // time, but does not re-arm an idle timer while capture is in progress.
        startEngineWarmUp(armIdleEviction: false, prewarmRefinerAfter: false)
    }

    /// If an optional refiner is cold-loading or still completing a timed-out request when the user
    /// presses the hotkey again, cancel and evict it during capture. Both the recognition warm-up
    /// and the eventual transcription await this boundary, so a rapid second dictation cannot
    /// recreate the contention F206 removed.
    private func prepareRefinerForCapture() {
        guard refinerIsWarming || refinerRequiresReleaseBeforeRecognition else { return }
        beginRefinerRelease()
    }

    /// Starts one temporary, wait-for-exit release of the optional helper. The task stays visible
    /// until it has actually finished so every recognition launch can use it as an admission
    /// boundary. A resident, already-idle refiner is intentionally not released here.
    private func beginRefinerRelease() {
        guard refinerReleaseForCapture == nil else { return }
        invalidateRefinerWarmth()
        refinerRequiresReleaseBeforeRecognition = false
        // Request termination immediately (important for a user disabling the feature) and then
        // retain the asynchronous `evict` boundary until the helper has actually exited.
        refiner.shutdown()
        let generation = refinerWarmGeneration
        let task = Task { @MainActor [weak self, refiner] in
            await refiner.evict()
            guard let self, self.refinerWarmGeneration == generation else { return }
            self.refinerReleaseForCapture = nil
        }
        refinerReleaseForCapture = task
    }

    /// The polishing model is optional; recognition is not. In particular, never cold-start the
    /// 4B/8B refiner alongside ASR on press-down — on an 18 GB Mac that turned a sub-second Qwen
    /// dictation into a multi-second wait. Once ASR has delivered, a background warm can help the
    /// *next* dictation without delaying this one.
    private func prewarmRefinerWhenSafe() {
        guard enabled,
              refineEnabled,
              refineRuntimeAvailability(),
              !isMeetingTranscriptionRunning(),
              canWarmRefinerWithoutContention,
              engineWarmTask == nil,
              refinerReleaseForCapture == nil,
              !refinerIsWarm,
              !refinerIsWarming else { return }
        refinerIsWarming = true
        let generation = refinerWarmGeneration
        let task = Task { @MainActor [weak self, refiner] in
            // This check is intentionally before the actor call. A meeting release and this task
            // both run on MainActor, so they cannot interleave between it and enqueueing warmUp().
            guard let self,
                  !Task.isCancelled,
                  self.refinerWarmGeneration == generation else { return }
            // The check above can run one MainActor turn before this task starts. Recheck actual
            // meeting admission immediately before a multi-GB process launches.
            guard !self.isMeetingTranscriptionRunning() else {
                self.refinerWarmTask = nil
                self.refinerIsWarming = false
                return
            }
            let warmed = await refiner.warmUp()
            guard !Task.isCancelled,
                  self.refinerWarmGeneration == generation else { return }
            self.refinerWarmTask = nil
            self.refinerIsWarming = false
            self.refinerIsWarm = warmed
                && self.enabled
                && self.refineEnabled
                && self.refineRuntimeAvailability()
        }
        refinerWarmTask = task
    }

    private var canWarmRefinerWithoutContention: Bool {
        switch status {
        case .idle: true
        case .disabled, .listening, .transcribing, .delivering, .error: false
        }
    }

    private func invalidateRefinerWarmth() {
        refinerWarmGeneration &+= 1
        refinerWarmTask?.cancel()
        refinerWarmTask = nil
        refinerIsWarm = false
        refinerIsWarming = false
    }

    private func invalidateEngineWarmth() {
        engineWarmGeneration &+= 1
        engineWarmTask?.cancel()
        engineWarmTask = nil
    }

    /// Starts only the recognition helper. The optional refiner has a separate warm policy because
    /// its multi-GB load must never race recognition or a meeting model.
    private func startEngineWarmUp(armIdleEviction: Bool, prewarmRefinerAfter: Bool) {
        guard enabled,
              !isMeetingTranscriptionRunning(),
              engineWarmTask == nil else { return }
        let generation = engineWarmGeneration
        let refinerRelease = refinerReleaseForCapture
        let task = Task { @MainActor [weak self, engine, log] in
            // Same MainActor generation barrier as the refiner: a release that wins first makes a
            // stale task a no-op instead of a late process spawn during meeting transcription.
            // A press that evicts a cold/timed-out refiner also arrives here before ASR warm-up,
            // rather than only at the later transcribe boundary.
            await refinerRelease?.value
            guard let self,
                  !Task.isCancelled,
                  self.engineWarmGeneration == generation else { return }
            // `hasActiveTranscription` can change after the synchronous admission check above but
            // before this queued task begins. Do not make the meeting wait for an avoidable model
            // spawn in that window.
            guard !self.isMeetingTranscriptionRunning() else {
                self.engineWarmTask = nil
                return
            }
            do {
                try await engine.warmUp()
                guard !Task.isCancelled,
                      self.engineWarmGeneration == generation else { return }
                self.engineWarmTask = nil
                if prewarmRefinerAfter { self.prewarmRefinerWhenSafe() }
                if armIdleEviction { self.scheduleIdleEviction() }
            } catch {
                guard !Task.isCancelled,
                      self.engineWarmGeneration == generation else { return }
                self.engineWarmTask = nil
                log.error("warm-up failed: \(DiagnosticsBundleBuilder.publicLogDescription(error), privacy: .public)")
            }
        }
        engineWarmTask = task
    }

    func warmUpIfNeeded() {
        log.notice("warm-up starting for \(self.selectedEngine.rawValue, privacy: .public)")
        startEngineWarmUp(armIdleEviction: true, prewarmRefinerAfter: true)
    }

    /// Used after the last meeting ASR pass completes. It restores fast dictation without bringing
    /// the optional 4B/8B refiner back into memory.
    func warmRecognitionEngineIfNeeded() {
        startEngineWarmUp(armIdleEviction: true, prewarmRefinerAfter: false)
    }

    // MARK: - Enable / disable

    /// Start (or restart) the global hotkey tap and reflect the result in `hotkeyActive`/`status`.
    /// Shared by `apply()` and the `hotkey` didSet so changing the trigger key can never leave a
    /// stale `.error`/`.idle` verdict or a stale `hotkeyActive` behind (F39).
    private func applyHotkeyStart() {
        let started = hotkeyMonitor.start(hotkey: hotkey)
        hotkeyActive = started
        if started {
            status = .idle
        } else {
            log.error("event tap could not be created — Accessibility/Input Monitoring off")
            status = .error("Enable Accessibility (and, if needed, Input Monitoring) for WhisperMeet in System Settings → Privacy & Security.")
        }
    }

    private func apply() {
        if enabled {
            ensureHelperInstalled()
            log.notice("dictation enabled (hotkey \(self.hotkey.keyCode, privacy: .public) mode \(self.hotkey.mode.rawValue, privacy: .public))")
            applyHotkeyStart()
            Task { await requestMicIfNeeded() }
            warmUpIfNeeded()
        } else {
            hotkeyMonitor.stop()
            hotkeyActive = false
            recorder.cancel()             // never leave the mic hot after the user disables dictation
            captureWatchdog.cancel()
            dismissWorkItem?.cancel()
            busyHideWorkItem?.cancel()
            idleEvictWorkItem?.cancel()
            session = DictationSession()  // reset so a stale .listening can't transcribe leaked audio on re-enable
            overlay.hide()
            invalidateEngineWarmth()
            engine.shutdown()             // release the resident model/subprocess when disabled
            // Keep a real wait-for-exit boundary in case the user re-enables dictation before the
            // optional helper has finished terminating.
            beginRefinerRelease()
            status = .disabled
            log.notice("dictation disabled")
        }
    }

    /// Keep every installed local-runtime helper in sync with this app build — not only the selected
    /// dictation engine — so a shipped fix reaches disk on launch instead of waiting for a reinstall
    /// or a model switch (F25, F207). This includes Qwen's one-shot *meeting* helper: an old copy
    /// chose the Chinese forced aligner for any English chunk containing a Chinese name. The
    /// reconciliation is atomic and content-gated, so a concurrent helper reader never observes a
    /// partial script and an already-current runtime incurs no write.
    private func ensureHelperInstalled() {
        let files = FileManager.default
        var helpers = Self.bundledDictationHelpers(fileManager: files)
        helpers.append(Self.bundledRefineHelper(fileManager: files))
        // The one-shot Qwen meeting helper is read at process launch. Atomic replacement makes
        // readers safe, but defer a nonessential update while an existing meeting pass owns it.
        if !isMeetingTranscriptionRunning() {
            helpers.append(Self.bundledQwenMeetingHelper(fileManager: files))
        }
        for (helper, outcome) in zip(helpers, DictationHelperSync.sync(helpers, fileManager: files)) {
            switch outcome {
            case let .synced(name):
                log.notice("\(name, privacy: .public) synced from app bundle into runtime")
            case let .failed(name, message):
                log.error("failed to install dictation helper \(name, privacy: .public): \(message, privacy: .public)")
            case let .bundleMissing(name):
                // Only a real problem when there is also no installed copy to fall back on.
                if !files.fileExists(atPath: helper.installedScript.path) {
                    log.error("\(name, privacy: .public) missing and no bundled copy found")
                }
            case .upToDate, .runtimeAbsent:
                break
            }
        }
    }

    /// Build a `DictationHelperSync.Helper` for every engine in the tested `installedHelperPlan`
    /// (all engine cases — deliberately not `selectedEngine`, which was the F25 bug), attaching the
    /// bundle bytes and whether that engine's runtime is installed.
    private static func bundledDictationHelpers(
        fileManager files: FileManager
    ) -> [DictationHelperSync.Helper] {
        DictationHelperSync.installedHelperPlan().map { location in
            DictationHelperSync.Helper(
                name: location.resource,
                bundledData: Bundle.main.url(forResource: location.resource, withExtension: "py")
                    .flatMap { try? Data(contentsOf: $0) },
                installedScript: location.installedScript,
                runtimeInstalled: files.fileExists(atPath: location.pythonExecutable.path)
            )
        }
    }

    /// The F200 refine helper rides the same F25 helper-sync so an existing Summarizer install
    /// (which predates `refine_server.py`) self-heals at launch/enable instead of demanding a
    /// reinstall. `DictationHelperSync.sync` is engine-agnostic: an absent runtime is skipped,
    /// never created.
    private static func bundledRefineHelper(
        fileManager files: FileManager
    ) -> DictationHelperSync.Helper {
        DictationHelperSync.Helper(
            name: "refine_server",
            bundledData: Bundle.main.url(forResource: "refine_server", withExtension: "py")
                .flatMap { try? Data(contentsOf: $0) },
            installedScript: SummarizerRuntime.refineHelperScript(),
            runtimeInstalled: files.isExecutableFile(
                atPath: SummarizerRuntime.pythonExecutable().path
            )
        )
    }

    private static func bundledQwenMeetingHelper(
        fileManager files: FileManager
    ) -> DictationHelperSync.Helper {
        qwenMeetingHelper(
            bundledData: Bundle.main.url(forResource: "qwen_transcribe", withExtension: "py")
                .flatMap { try? Data(contentsOf: $0) },
            fileManager: files
        )
    }

    /// The meeting helper is the one file deliberately excluded from `QwenASRRuntime.isInstalled()`:
    /// a missing/stale copy is exactly what this repair may restore. Require the actual Python and
    /// both model artifacts instead, so a partial installer never gains a lone helper script.
    /// Kept internal for the headless F207 sync test; production supplies bytes from `Bundle.main`.
    static func qwenMeetingHelper(
        bundledData: Data?,
        applicationSupport: URL? = nil,
        fileManager files: FileManager = .default
    ) -> DictationHelperSync.Helper {
        let python = QwenASRRuntime.pythonExecutable(applicationSupport: applicationSupport)
        let model = QwenASRRuntime.modelDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("model.safetensors")
        let aligner = QwenASRRuntime.alignerDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("model.safetensors")
        return DictationHelperSync.Helper(
            name: "qwen_transcribe",
            bundledData: bundledData,
            installedScript: QwenASRRuntime.helperScript(applicationSupport: applicationSupport),
            runtimeInstalled: files.isExecutableFile(atPath: python.path)
                && files.fileExists(atPath: model.path)
                && files.fileExists(atPath: aligner.path)
        )
    }

    deinit {
        hotkeyMonitor.stop()
        engine.shutdown()
        refiner.shutdown()
    }

    private func requestMicIfNeeded() async {
        _ = await recorder.requestPermission()
    }

    // MARK: - Hotkey events

    func handlePressStart() {
        // Every refusal below must clear toggle mode's latched state; otherwise the monitor keeps
        // believing dictation is "on" and the next press fires an end edge that silently no-ops (F38).
        guard enabled, !isSwitchingModel else { hotkeyMonitor.resetToggleState(); return }
        if isMicrophoneBusy() {
            log.notice("dictation press ignored — microphone busy (meeting or mic test)")
            flashBusy()
            hotkeyMonitor.resetToggleState()
            return
        }
        if isRecognitionRuntimeInstalling() {
            log.notice("dictation press ignored — a recognition model is installing (avoids CPU/memory contention)")
            flashBusy()
            hotkeyMonitor.resetToggleState()
            return
        }
        if isMeetingTranscriptionRunning() {
            log.notice("dictation press ignored — a meeting is transcribing (avoids local-model contention)")
            flashBusy()
            hotkeyMonitor.resetToggleState()
            return
        }
        switch session.handle(.startPressed) {
        case .startCapture:
            startCapture()
            prepareRefinerForCapture()
            prewarmEngineForCapture()
        case .busy:
            // A press arrived while a dictation is still in flight — leave the in-flight session and
            // its overlay untouched. Never reset it here; that would drop the pending transcript.
            // The monitor's toggle IS reset so the user's next press starts a fresh capture.
            log.notice("dictation press ignored — busy")
            hotkeyMonitor.resetToggleState()
        default:
            hotkeyMonitor.resetToggleState()
        }
    }

    private func handlePressEnd() {
        _ = beginTranscriptionIfNeeded()
    }

    private func startCapture() {
        do {
            dismissWorkItem?.cancel()
            busyHideWorkItem?.cancel()
            idleEvictWorkItem?.cancel() // fresh activity resets the idle-eviction clock
            try recorder.start { [weak self] level in
                Task { @MainActor [weak self] in self?.overlay.update(level: level) }
            }
            status = .listening
            overlay.show(.listening)
            captureWatchdog.arm()
            log.notice("listening")
        } catch {
            _ = session.handle(.engineFailed(error.localizedDescription))
            hotkeyMonitor.resetToggleState() // capture never began — never leave toggle latched "on" (F38)
            fail(error.localizedDescription)
        }
    }

    private func beginTranscriptionIfNeeded() -> Bool {
        captureWatchdog.cancel()
        guard recorder.isRecording else { return false }
        let clip: (url: URL, duration: TimeInterval)
        do {
            clip = try recorder.stop()
        } catch {
            // Capture produced no usable audio (or wasn't recording). Drive the machine out of
            // .listening and release the mic instead of wedging there forever; treat it as "nothing
            // heard" rather than a hard error.
            log.notice("dictation capture yielded no audio: \(DiagnosticsBundleBuilder.publicLogDescription(error), privacy: .public)")
            recorder.cancel()
            _ = session.handle(.dismiss)
            status = .idle
            scheduleIdleEviction()
            overlay.show(.empty)
            logStore.record(text: "", outcome: .empty)
            scheduleDismiss(after: 1.2)
            return false
        }
        log.notice("clip \(clip.duration, format: .fixed(precision: 2))s")

        let action = session.handle(.endPressed(clipDuration: clip.duration))
        switch action {
        case .discard:
            try? FileManager.default.removeItem(at: clip.url)
            status = .idle
            scheduleIdleEviction() // a too-short tap still leaves the model warm — re-arm eviction
            overlay.hide()
            return true
        case .transcribe:
            status = .transcribing
            overlay.show(.transcribing)
            transcribe(clip: clip)
            return true
        default:
            try? FileManager.default.removeItem(at: clip.url)
            return false
        }
    }

    private func transcribe(clip: (url: URL, duration: TimeInterval)) {
        let language = self.language
        let selection = selectedEngine
        // Same business vocabulary the meeting pipeline already feeds into Whisper's
        // `initial_prompt`, capped/formatted identically via the shared `VocabularyPrompt` helper.
        // Qwen has no prompt parameter, so the capability check prevents a misleading no-op.
        let vocab = useVocabulary && selection.supportsVocabularyPrompt
            ? vocabularyProvider()
            : []
        let prompt = VocabularyPrompt.build(vocab)
        let initialPrompt = prompt.isEmpty ? nil : prompt
        let refinerRelease = refinerReleaseForCapture
        // Snapshot the refine decision with the other settings: mid-flight toggle changes must not
        // switch behavior halfway through a dictation.
        // A cold refiner is a nice-to-have, never a reason to hold this clip. It warms only after
        // delivery, so the first post-eviction dictation gets fast raw text rather than a timeout.
        let refineOn = refineEnabled && refinerIsWarm && refineRuntimeAvailability()
        Task { [engine, log, refiner] in
            let started = Date()
            do {
                // A just-started optional model is cancelled on press-down. Ensure it has actually
                // left unified memory before the recognition helper runs, even for a very short tap.
                await refinerRelease?.value
                let result = try await engine.transcribe(wavAt: clip.url, language: language, initialPrompt: initialPrompt)
                try? FileManager.default.removeItem(at: clip.url)
                var cleaned = DictationTextCleanup.clean(result.text)
                // Phantom-on-silence guard: with an initial_prompt present, Whisper can regurgitate
                // the vocabulary list on a silence/noise clip. Only drop it when the audio actually
                // scored as silence — otherwise a genuinely dictated run of vocab terms (e.g. two
                // adjacent product names) would be silently deleted (see shouldDropAsPromptEcho).
                if initialPrompt != nil,
                   VocabularyPrompt.shouldDropAsPromptEcho(
                    cleaned, terms: vocab, noSpeechProb: result.noSpeechProb) {
                    cleaned = ""
                }
                log.notice("\(selection.rawValue, privacy: .public) transcribed in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
                var rawText: String?
                var refinement: String?
                if refineOn, !cleaned.isEmpty {
                    await MainActor.run { if self.enabled { self.overlay.show(.refining) } }
                    let attempt = await refiner.attempt(
                        text: cleaned, languageCode: result.languageCode)
                    refinement = attempt.outcome.rawValue
                    if attempt.outcome == .refined {
                        rawText = cleaned
                        cleaned = attempt.text
                    } else if attempt.outcome == .rawError {
                        // A crashed/helper-missing refiner is not actually resident. Clear the
                        // optimistic warm state so the next dictation stays on its immediate raw
                        // path while a later idle window may retry the optional warm-up.
                        await MainActor.run {
                            self.beginRefinerRelease()
                        }
                    } else if attempt.outcome == .rawTimeout || attempt.outcome == .rawBusy {
                        // `DictationRefiner` correctly keeps an abandoned request busy until it
                        // really drains. Raw text has already been delivered, but the next ASR
                        // must not warm alongside that still-running 4B/8B request.
                        await MainActor.run {
                            self.refinerRequiresReleaseBeforeRecognition = true
                        }
                    }
                    log.notice("refinement \(attempt.outcome.rawValue, privacy: .public) in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s total")
                }
                await MainActor.run {
                    self.finish(text: cleaned, rawText: rawText, refinement: refinement)
                }
            } catch {
                try? FileManager.default.removeItem(at: clip.url)
                log.error("transcription failed: \(DiagnosticsBundleBuilder.publicLogDescription(error), privacy: .public)")
                await MainActor.run {
                    guard self.enabled else { return }
                    _ = self.session.handle(.engineFailed(error.localizedDescription))
                    self.fail(error.localizedDescription)
                }
            }
        }
    }

    private func finish(text: String, rawText: String? = nil, refinement: String? = nil) {
        guard enabled else { return } // feature was disabled mid-transcribe — drop the result, don't paste
        switch session.handle(.transcriptReady(text)) {
        case let .deliver(payload):
            status = .delivering
            let delivery = autoPaste ? TextInjector.deliver(payload) : deliverClipboardOnly(payload)
            _ = session.handle(.delivered)
            switch delivery {
            case .pasted: overlay.show(.done)
            case .clipboard: overlay.show(.copied); clipboardNotifier()
            }
            log.notice("delivered via \(delivery == .pasted ? "paste" : "clipboard", privacy: .public)")
            logStore.record(
                text: payload,
                outcome: delivery == .pasted ? .pasted : .clipboard,
                rawText: rawText,
                refinement: refinement
            )
            scheduleDismiss(after: 1.1)
        case .none where session.state == .failed(.emptyTranscript):
            overlay.show(.empty)
            logStore.record(text: "", outcome: .empty)
            scheduleDismiss(after: 1.3)
            status = .idle
        default:
            scheduleDismiss(after: 1.0)
            status = .idle
        }
    }

    private func deliverClipboardOnly(_ text: String) -> TextInjector.Delivery {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return .clipboard
    }

    private func flashBusy() {
        // Meeting-active guard path. Only flash when idle — never disrupt an in-flight or
        // still-settling session. Uses its OWN work item so it can never cancel a pending
        // session-resetting dismiss (which would leave the session wedged outside .idle).
        guard session.state == .idle else { return }
        overlay.show(.busy)
        busyHideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.overlay.hide() }
        busyHideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }

    private func fail(_ message: String) {
        status = .error(message)
        overlay.show(.error)
        logStore.record(text: "", outcome: .failed(message))
        scheduleDismiss(after: 1.6)
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        dismissWorkItem?.cancel()
        busyHideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.overlay.hide()
            _ = self?.session.handle(.dismiss)
            self?.status = .idle
            self?.prewarmRefinerWhenSafe()
            self?.scheduleIdleEviction()
        }
        dismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// Frees the resident ~1.6 GB warm turbo model after dictation has sat idle for a while. Any
    /// fresh activity (a new capture) cancels this before it fires; it never fires while `isActive`.
    private func scheduleIdleEviction() {
        idleEvictWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.enabled, !self.isActive else { return }
            self.log.notice("evicting idle warm dictation model")
            self.invalidateEngineWarmth()
            self.engine.shutdown()
            // A new press will await this before it restarts recognition. `shutdown()` alone is
            // fire-and-forget for the helper, which is not enough on unified memory.
            self.beginRefinerRelease()
        }
        idleEvictWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + idleEvictSeconds, execute: item)
    }


    /// Injectable because `UNUserNotificationCenter.current()` requires a real app bundle and
    /// raises an NSException in headless test processes — the F200 wiring tests are the first to
    /// drive a clipboard delivery to completion and hit exactly that.
    var clipboardNotifier: () -> Void = DictationController.postClipboardNotification

    private static func postClipboardNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Dictation copied"
        content.body = "Transcript is on the clipboard — press ⌘V to paste."
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Diagnostics / self-test

    func diagnostics() -> DictationDiagnostics {
        let files = FileManager.default
        let runtimeInstalled: Bool
        let helperInstalled: Bool
        let modelReady: Bool
        switch selectedEngine {
        case .whisperTurbo:
            runtimeInstalled = files.isExecutableFile(
                atPath: LocalWhisperRuntime.pythonExecutable().path
            )
            helperInstalled = files.fileExists(
                atPath: LocalWhisperRuntime.dictationServerScript().path
            )
            modelReady = LocalWhisperRuntime.mlxModelCached()
        case .qwenBalanced:
            runtimeInstalled = QwenASRRuntime.isInstalled()
            helperInstalled = files.fileExists(
                atPath: QwenASRRuntime.dictationHelperScript().path
            )
            modelReady = files.fileExists(
                atPath: QwenASRRuntime.modelDirectory()
                    .appendingPathComponent("model.safetensors").path
            )
        }
        return DictationDiagnostics(
            engineName: selectedEngine.displayName,
            runtimeInstalled: runtimeInstalled,
            helperInstalled: helperInstalled,
            modelReady: modelReady,
            microphoneGranted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            accessibilityGranted: HotkeyMonitor.isAccessibilityTrusted,
            hotkeyActive: hotkeyActive
        )
    }

    func runSelfTest() {
        guard !isSelfTesting, !isSwitchingModel else { return }
        guard !isMeetingTranscriptionRunning() else {
            selfTestResult = "Finish the current meeting transcription before testing Quick Dictation."
            return
        }
        isSelfTesting = true
        selfTestResult = nil
        idleEvictWorkItem?.cancel() // self-test is activity — don't let a stale timer evict mid-test
        ensureHelperInstalled()
        let engineName = selectedEngine.displayName
        Task { [engine] in
            let samples = [Float](repeating: 0, count: 16_000) // 1s of silence @16kHz
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("dictation-selftest-\(UUID().uuidString).wav")
            var message: String
            do {
                try WhisperCore.WAVWriter.wavData(from: samples, sampleRate: 16_000).write(to: url)
                _ = try await engine.transcribe(wavAt: url, language: .automatic, initialPrompt: nil)
                message = "✓ \(engineName) responded — dictation pipeline is working."
            } catch {
                message = "✗ \(error.localizedDescription)"
            }
            try? FileManager.default.removeItem(at: url)
            await MainActor.run {
                self.selfTestResult = message
                self.isSelfTesting = false
                if self.enabled { self.scheduleIdleEviction() } else { self.engine.shutdown() }
            }
        }
    }

    private func persist() {
        defaults.set(enabled, forKey: Self.enabledKey)
        defaults.set(try? JSONEncoder().encode(hotkey), forKey: Self.hotkeyKey)
        defaults.set(language.rawValue, forKey: Self.languageKey)
        defaults.set(autoPaste, forKey: Self.autoPasteKey)
        defaults.set(useVocabulary, forKey: Self.useVocabularyKey)
        defaults.set(refineEnabled, forKey: Self.refineEnabledKey)
        defaults.set(selectedEngine.rawValue, forKey: Self.engineKey)
    }
}
