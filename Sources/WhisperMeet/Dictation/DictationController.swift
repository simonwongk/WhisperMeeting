// Sources/WhisperMeet/Dictation/DictationController.swift
import AppKit
import AVFoundation
import Foundation
import UserNotifications
import WhisperCore
import os

/// Snapshot of the dictation feature's health, gathered on demand for the Dictation tab.
struct DictationDiagnostics: Equatable {
    var engineName: String
    var runtimeInstalled: Bool
    var helperInstalled: Bool
    var modelReady: Bool
    /// Whether Install / Repair can make `modelReady` true (F823). Not for Whisper Turbo on a Mac
    /// the warm MLX helper cannot run on (Intel): dictation there runs openai-whisper's own turbo
    /// checkpoint, which no installer fetches — whisper downloads it on the first dictation — so the
    /// row used to stay ✗ beside a Repair that could never change it.
    var modelRepairable: Bool = true
    var microphoneGranted: Bool
    var accessibilityGranted: Bool
    var hotkeyActive: Bool

    /// Whether the tab offers Install / Repair: something it can fix is missing (F823).
    var offersRepair: Bool {
        !runtimeInstalled || !helperInstalled || (!modelReady && modelRepairable)
    }
}

/// Owns the quick-dictation feature end to end: hotkey → capture → selected local model → paste,
/// driven by the pure `DictationSession`. Independent of the meeting pipeline.
@MainActor
final class DictationController: ObservableObject {
    enum Status: Equatable {
        case disabled, idle, listening, transcribing, delivering
        case error(String)
    }

    @Published private(set) var status: Status = .disabled { didSet { noteActivityChange() } }
    /// The dictation model's first-run download is running (F823), as the engine reports it. Kept
    /// apart from `status`, which is a dictation's own state and drives `isActive`: a download is
    /// not a dictation in flight, and a meeting may still transcribe beside it.
    @Published private(set) var isDownloadingModel = false
    @Published var enabled: Bool { didSet { persist(); apply() } }
    @Published var hotkey: DictationHotkey {
        didSet {
            if hotkey != oldValue { persistHotkey() }
            guard enabled else { return }
            armChangedHotkey()
        }
    }
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

    var isAccessibilityTrusted: Bool { accessibilityTrusted() }

    /// Settings' "Grant…" (F523). The system prompt only opens System Settings; nothing tells the app
    /// when the user switches WhisperMeet on there. So when the trigger's tap has failed — or an
    /// F-key trigger is armed listen-only for want of it (F547) — this also checks once a second,
    /// for two minutes, and arms the trigger as soon as the process is trusted, while the user is
    /// still in System Settings. Coming back to WhisperMeet retries as well (`retryFailedHotkey`),
    /// so a grant after the two minutes is not lost either.
    func requestAccessibility() {
        promptForAccessibility()
        accessibilityPoll?.cancel()
        accessibilityPoll = nil
        guard enabled, hotkeyTapFailed || hotkeyMonitor.isArmedWithoutHoldingBack else { return }
        accessibilityPoll = Task { @MainActor [weak self] in
            for _ in 0..<Self.accessibilityPollChecks {
                guard let pause = self?.accessibilityPollSleep else { return }
                do { try await pause(Self.accessibilityPollInterval) } catch { return }
                guard let self, !Task.isCancelled else { return }
                if self.accessibilityTrusted() { self.retryFailedHotkey() }
                guard self.enabled,
                      self.hotkeyTapFailed || self.hotkeyMonitor.isArmedWithoutHoldingBack else { break }
            }
            self?.accessibilityPoll = nil
        }
    }

    /// Seams for F523, assigned by tests after construction: the process's Accessibility trust, the
    /// system prompt that asks for it, and the pause between checks after that prompt.
    var accessibilityTrusted: () -> Bool = { HotkeyMonitor.isAccessibilityTrusted }
    var promptForAccessibility: () -> Void = { HotkeyMonitor.requestAccessibility() }
    var accessibilityPollSleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// Whether the checks that follow "Grant…" are still running.
    var isAwaitingAccessibility: Bool { accessibilityPoll != nil }
    static let accessibilityPollChecks = 120
    static let accessibilityPollInterval: Duration = .seconds(1)
    private var accessibilityPoll: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private let activationNotifications: NotificationCenter

    // MARK: - The F-key trigger's active tap and Accessibility (F547)
    //
    // An active tap holds every key-down and key-up in the session until it answers. Other apps with
    // one froze the whole keyboard when Accessibility was revoked under it: the system disabled the
    // tap, their callback re-enabled it, and nothing re-checked the grant (deskflow #9562 and its
    // fix #9579, slovo #73; slovo #112 adds that the disable may not arrive at all). So here:
    //
    // - a disabled tap is never re-enabled; `handleTriggerTapLost` re-arms through `start`, whose
    //   new `tapCreate` comes back NULL without the grant, and the trigger then falls back to
    //   listen-only or fails with F633's status;
    // - while the active tap is armed, the grant is re-checked with a probe tap once a second and
    //   whenever WhisperMeet comes to the front;
    // - every branch that cannot vouch for the tap arms listen-only until WhisperMeet next comes to
    //   the front: a loss the system calls "user input", and a third loss since the last time.

    /// Whether an active tap can be created now. Tests assign it; none creates a real probe tap.
    var activeTapProbe: () -> Bool = { HotkeyMonitor.canCreateActiveTap() }
    /// The pause between probes while the active tap is armed. Tests step it by hand.
    var activeTapCheckSleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    static let activeTapCheckInterval: Duration = .seconds(1)
    /// Losses of the active tap since WhisperMeet last came to the front, at which the trigger stops
    /// trying to hold the key back.
    static let triggerTapLossLimit = 3
    private var triggerTapLosses = 0
    private var activeTapCheck: Task<Void, Never>?
    private var activeTapCheckGeneration = 0

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
    @Published private(set) var isSelfTesting = false { didSet { noteActivityChange() } }
    @Published private(set) var isSwitchingModel = false { didSet { noteActivityChange() } }

    private let defaults: UserDefaults
    private let hotkeyMonitor: any HotkeyMonitoring
    private let recorder: any DictationRecording
    private let overlay: any DictationOverlayPresenting
    private let engine: SelectableDictationEngine
    private let refiner: any DictationTextRefining
    private let textInjector: TextInjector
    private let engineFactory: (DictationTranscriptionEngine) -> DictationEngine
    private let captureTimeout: Duration
    private let captureSleep: DictationCaptureWatchdog.Sleep
    private var session = DictationSession()
    private var isMicrophoneBusy: () -> Bool = { false }
    private var isRecognitionRuntimeInstalling: () -> Bool = { false }
    private var isMeetingTranscriptionRunning: () -> Bool = { false }
    private var vocabularyProvider: () -> [String] = { [] }
    /// The user's replacement rules and the vocabulary that guards their Chinese word edges (F821).
    private var replacementRulesProvider: () -> [ReplacementRule] = { [] }
    private var knownTermsProvider: () -> [String] = { [] }
    /// Where a Chinese word begins and ends, for the replacement rules (F594's seam, as
    /// `AppModel.cjkWordSegmenter`): NLTokenizer in the app; tests pin a fixed segmentation.
    var cjkWordSegmenter: CJKWordEvidence.Segmenter = NaturalLanguageWordSegmenter.wordRanges
    private var dismissWorkItem: DispatchWorkItem?
    private var busyHideWorkItem: DispatchWorkItem?
    /// A busy flash is showing and has been announced (F537): its hide is still pending. Derived,
    /// so every path that cancels the flash also ends it.
    private var isFlashingBusy: Bool { busyHideWorkItem.map { !$0.isCancelled } ?? false }
    /// What the pill is saying, apart from a busy flash; nil while it is hidden. The flash puts this
    /// back when it ends, so refusing a press never hides a dictation that is still in flight (F443).
    private var shownPhase: DictationOverlay.Phase?
    /// A dictation not pasted because of secure input, kept for the pill's Copy button and nowhere
    /// else — not the clipboard, not the history — and dropped when that pill goes (F586).
    private(set) var heldSecureDictation: String?
    /// How long the pill offering Copy stays up, and so how long the text is held (F586): long
    /// enough to move the pointer to it, where a result pill is gone in 1.1 s. A var so a test can
    /// shorten it.
    var secureCopyWindow: TimeInterval = 6
    /// What had focus when this dictation's key went down; the paste is checked against it (F445).
    private var pressTarget: FocusedTextField.Probe?
    private var idleEvictWorkItem: DispatchWorkItem?
    private var hotkeyActive = false
    /// The last attempt to arm the trigger failed: its event tap could not be created, which is
    /// what a missing Accessibility grant looks like (F523). Kept apart from `hotkeyActive`, which
    /// is also false before the first arm.
    private var hotkeyTapFailed = false
    /// The trigger `applyHotkeyStart` last handed the monitor, and before that the stored hotkey: in
    /// the app nothing can start a dictation before the first arm, and a test built with
    /// `activateOnInit: false` supplies a monitor already running the stored hotkey.
    private var armedHotkey: DictationHotkey = .rightOption
    /// Both warm-up tasks are cancellable and generation-guarded. A meeting release must prevent a
    /// task that was queued while idle from launching a model after that meeting has claimed memory.
    private var engineWarmTask: Task<Void, Never>?
    private var engineWarmGeneration = 0
    /// The optional polishing model is deliberately warmed only when it cannot contend with ASR.
    /// A generation invalidates an old asynchronous warm-up after eviction/disable.
    private var refinerWarmTask: Task<Void, Never>?
    private var refinerIsWarm = false
    /// Whether the optional refiner is resident, so the next dictation is offered to it. Tests wait
    /// on this rather than on a count of yields.
    var isRefinerReady: Bool { refinerIsWarm }
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

    /// `defaults` follows the library (F550): a `WHISPERMEET_LIBRARY` instance keeps its dictation
    /// settings apart from the real library's, as `AppModel`'s convenience init does.
    init(
        defaults: UserDefaults = WhisperMeetLibrary.defaults(),
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
        textInjector: TextInjector? = nil,
        idleEvictSeconds: TimeInterval = 300,
        activationNotifications: NotificationCenter = .default,
        activateOnInit: Bool = true
    ) {
        self.defaults = defaults
        self.recorder = recorder
        self.overlay = overlay ?? DictationOverlay()
        self.textInjector = textInjector ?? TextInjector()
        self.hotkeyMonitor = hotkeyMonitor
        self.logStore = logStore ?? DictationLogStore()
        self.captureTimeout = captureTimeout
        self.captureSleep = captureSleep
        self.idleEvictSeconds = idleEvictSeconds
        self.activationNotifications = activationNotifications
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
        armedHotkey = hotkey
        self.overlay.onCopy = { [weak self] in self?.copyHeldSecureDictation() }
        // F823. The engine reports from its own queue. `DispatchQueue.main` keeps the reports in
        // the order they were made, so an engine's "stopped" can never land after the next "started".
        self.engine.observeModelDownload { [weak self] downloading in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.modelDownloadChanged(downloading) }
            }
        }

        hotkeyMonitor.onPressStart = { [weak self] in self?.handlePressStart() }
        hotkeyMonitor.onPressEnd = { [weak self] in self?.handlePressEnd() }
        hotkeyMonitor.onPressCancel = { [weak self] in self?.handlePressCancel() }
        hotkeyMonitor.onTriggerTapLost = { [weak self] loss in self?.handleTriggerTapLost(loss) }
        // F523, F547. NSApplication posts this on the main thread, so the retry runs before `post`
        // returns; the hop covers anything that posts it from elsewhere.
        activationObserver = activationNotifications.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.applicationBecameActive() }
            } else {
                Task { @MainActor in self?.applicationBecameActive() }
            }
        }
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

    /// Called each time `isActive` falls from true to false. A meeting transcription that arrived
    /// during a dictation waits in the queue rather than being refused (F470), and this is what
    /// starts it — without it the job would wait for the next unrelated queue event.
    func configureActivityEnded(_ handler: @escaping () -> Void) {
        onActivityEnded = handler
    }

    private var onActivityEnded: () -> Void = {}
    /// `isActive` as last observed by `noteActivityChange`, so the hook fires on the falling edge
    /// only — `status` passes through several active phases in one dictation.
    private var wasActive = false

    /// Run from the `didSet` of every stored input to `isActive`.
    private func noteActivityChange() {
        let active = isActive
        let ended = wasActive && !active
        wasActive = active
        if ended { onActivityEnded() }
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
        // The recognition and optional-refiner helpers own distinct child processes. Start both
        // exits before awaiting either one: two independent 5-second graceful shutdown windows
        // must overlap, while a meeting still waits for *both* models to release memory.
        async let engineRelease: Void = engine.evict()
        async let refinerRelease: Void = {
            if let pendingRefinerRelease {
                await pendingRefinerRelease.value
            } else {
                await refiner.evict()
            }
        }()
        await engineRelease
        await refinerRelease
        log.notice("released idle dictation models before meeting transcription")
    }

    /// Supplies the business vocabulary (same source meetings already feed into their
    /// `initial_prompt`) so Quick Dictation gets the same spelling nudge for proper nouns/jargon.
    func configureVocabulary(_ provider: @escaping () -> [String]) {
        self.vocabularyProvider = provider
    }

    /// Supplies the Business Vocabulary's replacement rules, which Quick Dictation applies to its
    /// text before pasting (F821, the user's decision of 2026-10-07), and the stored vocabulary,
    /// which keeps a Chinese rule out of a longer term the user taught the app (F594's known terms —
    /// the same list `AppModel.cjkWordEvidence` uses for the Improve sheet).
    func configureReplacementRules(
        _ rules: @escaping () -> [ReplacementRule],
        knownTerms: @escaping () -> [String]
    ) {
        replacementRulesProvider = rules
        knownTermsProvider = knownTerms
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
                // F827: the model's first-run download stalled or failed. Nothing falls back to
                // another engine for it any more, so this is the user's only notice that dictation
                // is not ready — the same pill and history entry a failed dictation gets, while
                // nothing is in flight to overwrite (`isActive`). A press retries (and resumes the
                // download).
                if let download = error as? DictationModelDownloadError, self.enabled, !self.isActive {
                    _ = self.session.handle(.engineFailed(download.message))
                    self.fail(download.message)
                }
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
    /// Shared by `apply()` and `armChangedHotkey()` so changing the trigger key can never leave a
    /// stale `.error`/`.idle` verdict or a stale `hotkeyActive` behind (F39). The one caller of the
    /// monitor's `start`, so `armedHotkey` is set here and nowhere else after `init`.
    ///
    /// A dictation in flight owns `status` until it settles (F446). Writing `.idle` over a live
    /// `.listening` made `isActive` false with the microphone on — so the meeting guard stopped
    /// guarding — and disarmed the capture watchdog, which finalizes only a `.listening` status.
    private func applyHotkeyStart() {
        armedHotkey = hotkey
        let started = hotkeyMonitor.start(hotkey: hotkey)
        hotkeyActive = started
        hotkeyTapFailed = !started
        if !started {
            log.error("event tap could not be created — Accessibility/Input Monitoring off")
            if session.state == .listening {
                // F633: `start` removed the old tap before failing to make the new one, so no key
                // can end this capture now; only the 120 s watchdog would have. End it the way its
                // own release or toggle-off would, so it is transcribed and delivered, and clear
                // toggle's on-state as the watchdog does (F78).
                log.notice("dictation trigger lost under a live capture; finishing that dictation")
                _ = beginTranscriptionIfNeeded()
                hotkeyMonitor.resetToggleState()
            }
        }
        updateActiveTapCheck()
        guard session.state == .idle else { return }
        status = settledStatus
    }

    /// What `status` says while the trigger's tap cannot be created.
    static let tapFailureMessage = "Enable Accessibility (and, if needed, Input Monitoring) for WhisperMeet in System Settings → Privacy & Security."

    /// What `status` settles to when no dictation is in flight (F633): idle, or the tap failure while
    /// the trigger is dead. Every path that ends a dictation writes this rather than `.idle`: the
    /// pill's dismiss runs up to 1.6 s after its dictation, and a trigger that failed to re-arm in
    /// that window was reported as working.
    private var settledStatus: Status {
        hotkeyTapFailed ? .error(Self.tapFailureMessage) : .idle
    }

    /// A trigger chosen while dictation is enabled (F584). Nothing waits: a trigger chosen but not
    /// armed is one the monitor does not hear, and both attempts that deferred one left a dictation
    /// on that no key shown in Settings could end.
    ///
    /// - The armed trigger chosen again is left alone mid-dictation (F446): Settings' "Change" hears
    ///   the trigger key itself, and rebuilding the tap under the dictation that key is holding is
    ///   what can lose its release. Idle, a re-apply still re-taps.
    /// - With no capture live — idle, transcribing, or showing a result — the new trigger is armed
    ///   now. A press over the result pill starts the next dictation (F443), and that should be the
    ///   new trigger's.
    /// - Listening, toggle to toggle takes over now: the on-state carries across
    ///   (`HotkeyMonitor.adopt`), so the new key's next press turns the dictation off.
    /// - Listening, any other change — hold on either side, which every change of mode has — first
    ///   ends the dictation through the same finish its own release or toggle-off takes, so it is
    ///   transcribed and delivered like any other (F445 leaves it on the clipboard if the app in
    ///   front is not the one its key was pressed in), and then arms. Adopted under the capture instead, a key chosen on its key-down ended the
    ///   dictation on that key's release, and a hold switched to toggle ignored the release and
    ///   left the capture to the 120 s watchdog.
    private func armChangedHotkey() {
        if hotkey == armedHotkey {
            if session.state == .idle { applyHotkeyStart() }
            return
        }
        let takesOver = armedHotkey.mode == .toggle && hotkey.mode == .toggle
        if session.state == .listening, !takesOver {
            log.notice("dictation trigger changed while listening; finishing that dictation first")
            _ = beginTranscriptionIfNeeded()
            // Ended without the monitor's own end edge, so its toggle on-state is cleared here, as
            // the watchdog clears it (F78), rather than left to `adopt`'s mode rule.
            hotkeyMonitor.resetToggleState()
        }
        applyHotkeyStart()
    }

    /// Arms the trigger again if the last attempt failed (F523). The tap is created only when the
    /// trigger is armed, and a missing Accessibility grant fails it; granting Accessibility later
    /// tells the app nothing, so without a retry the key stayed dead while Settings showed the grant
    /// in green. Called when WhisperMeet comes to the front and by `requestAccessibility`'s checks.
    /// A trigger that is working is left alone.
    ///
    /// So is an F-key trigger that is working listen-only because its active tap was refused
    /// (F547) — but only while no dictation is in flight, because re-arming under one is what F446
    /// found loses its release. Without this, granting Accessibility left the key reaching the app in
    /// front until the next toggle, key change or relaunch: the arm had "succeeded".
    func retryFailedHotkey() {
        guard enabled, needsRearm else { return }
        log.notice("retrying the dictation trigger's event tap")
        applyHotkeyStart()
    }

    /// Whether `retryFailedHotkey` has anything to do.
    private var needsRearm: Bool {
        hotkeyTapFailed || (hotkeyMonitor.isArmedWithoutHoldingBack && session.state == .idle)
    }

    /// WhisperMeet came to the front (F523, F547). An armed active tap is re-checked; a trigger that
    /// failed, or is listen-only, is retried — and a trigger that was made listen-only because its
    /// active tap could not be vouched for may hold the key back again, since coming to the front is
    /// the user's own step back into the app.
    func applicationBecameActive() {
        triggerTapLosses = 0
        hotkeyMonitor.mayHoldTriggerBack = true
        if hotkeyMonitor.isHoldingTriggerBack {
            checkActiveTap()
        } else {
            retryFailedHotkey()
        }
    }

    /// The system disabled the F-key trigger's active tap (F547). The monitor has already dispatched
    /// the edge the tap missed. Re-armed through `applyHotkeyStart`, so the new tap is created from
    /// scratch and refused without the grant; a loss the system attributes to user input, or a third
    /// loss since WhisperMeet last came to the front, re-arms listen-only instead.
    private func handleTriggerTapLost(_ loss: TriggerTapLoss) {
        guard enabled else { return }
        triggerTapLosses += 1
        if loss == .userInput || triggerTapLosses >= Self.triggerTapLossLimit {
            hotkeyMonitor.mayHoldTriggerBack = false
        }
        log.notice("the trigger's active tap was disabled (\(String(describing: loss), privacy: .public), loss \(self.triggerTapLosses, privacy: .public)); re-arming")
        applyHotkeyStart()
    }

    /// Re-arms the trigger if an active tap can no longer be created (F547): Accessibility was
    /// revoked or the app removed from the list, perhaps with no disable event at all. The re-arm's
    /// own `tapCreate` then fails too, so the trigger falls back to listen-only or fails.
    private func checkActiveTap() {
        guard enabled, hotkeyMonitor.isHoldingTriggerBack, !activeTapProbe() else { return }
        log.error("an active tap can no longer be created; re-arming the trigger without it")
        applyHotkeyStart()
    }

    /// Runs `checkActiveTap` once a second while the active tap is armed, and only then (F547).
    /// Called after every arm and on disable.
    private func updateActiveTapCheck() {
        guard enabled, hotkeyMonitor.isHoldingTriggerBack else {
            activeTapCheck?.cancel()
            activeTapCheck = nil
            return
        }
        guard activeTapCheck == nil else { return }
        activeTapCheckGeneration &+= 1
        let generation = activeTapCheckGeneration
        activeTapCheck = Task { @MainActor [weak self] in
            while true {
                // A re-arm inside `checkActiveTap` can cancel this very task; stop before pausing.
                guard !Task.isCancelled, let pause = self?.activeTapCheckSleep else { return }
                do { try await pause(Self.activeTapCheckInterval) } catch { return }
                guard let self, !Task.isCancelled, self.activeTapCheckGeneration == generation else { return }
                guard self.enabled, self.hotkeyMonitor.isHoldingTriggerBack else {
                    self.activeTapCheck = nil
                    return
                }
                self.checkActiveTap()
            }
        }
    }

    /// Whether the once-a-second check of the active tap is running.
    var isCheckingActiveTap: Bool { activeTapCheck != nil }

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
            hotkeyTapFailed = false
            accessibilityPoll?.cancel()
            accessibilityPoll = nil
            updateActiveTapCheck()
            recorder.cancel()             // never leave the mic hot after the user disables dictation
            captureWatchdog.cancel()
            dismissWorkItem?.cancel()
            busyHideWorkItem?.cancel()
            idleEvictWorkItem?.cancel()
            session = DictationSession()  // reset so a stale .listening can't transcribe leaked audio on re-enable
            hideOverlay()
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
        helpers.append(Self.bundledSummarizeHelper(fileManager: files))
        helpers.append(Self.bundledCorrectHelper(fileManager: files))
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

    /// The one-shot summary helper rides the same sync (F512). Its stall timeout relies on the
    /// heartbeat lines this helper prints; `setup-local-summarizer.sh` was otherwise the only thing
    /// that wrote it, so an existing install would have kept a silent copy — and a long, healthy
    /// prefill would then read as a stall.
    private static func bundledSummarizeHelper(
        fileManager files: FileManager
    ) -> DictationHelperSync.Helper {
        summarizeHelper(
            bundledData: Bundle.main.url(forResource: "summarize_local", withExtension: "py")
                .flatMap { try? Data(contentsOf: $0) },
            fileManager: files
        )
    }

    /// Requires the interpreter and the model, like `qwenMeetingHelper`, so an interrupted install
    /// never gains a lone helper script. Internal for the headless sync test.
    static func summarizeHelper(
        bundledData: Data?,
        applicationSupport: URL? = nil,
        fileManager files: FileManager = .default
    ) -> DictationHelperSync.Helper {
        let python = SummarizerRuntime.pythonExecutable(applicationSupport: applicationSupport)
        let model = SummarizerRuntime.modelDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("model.safetensors")
        return DictationHelperSync.Helper(
            name: "summarize_local",
            bundledData: bundledData,
            installedScript: SummarizerRuntime.helperScript(applicationSupport: applicationSupport),
            runtimeInstalled: files.isExecutableFile(atPath: python.path)
                && files.fileExists(atPath: model.path)
        )
    }

    /// The transcript-correction helper (F165) lives in the summarizer runtime, next to
    /// `summarize_local.py`, but was the one runtime helper this launch sync did not copy (F643): a
    /// fix to it (F475's context pre-flight and refusal of truncated output) reached an existing
    /// install only after the summarizer's Repair, while the app's Swift side already expected the
    /// new payload shape.
    private static func bundledCorrectHelper(
        fileManager files: FileManager
    ) -> DictationHelperSync.Helper {
        correctHelper(
            bundledData: Bundle.main.url(forResource: "correct_local", withExtension: "py")
                .flatMap { try? Data(contentsOf: $0) },
            fileManager: files
        )
    }

    /// The same runtime prerequisites as `summarizeHelper` — the interpreter and the model, since
    /// correction runs on the summarizer's model — so an interrupted install never gains a lone
    /// helper script. Internal for the headless sync test.
    static func correctHelper(
        bundledData: Data?,
        applicationSupport: URL? = nil,
        fileManager files: FileManager = .default
    ) -> DictationHelperSync.Helper {
        let python = SummarizerRuntime.pythonExecutable(applicationSupport: applicationSupport)
        let model = SummarizerRuntime.modelDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("model.safetensors")
        return DictationHelperSync.Helper(
            name: "correct_local",
            bundledData: bundledData,
            installedScript: SummarizerRuntime.correctionHelperScript(applicationSupport: applicationSupport),
            runtimeInstalled: files.isExecutableFile(atPath: python.path)
                && files.fileExists(atPath: model.path)
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
        if let activationObserver { activationNotifications.removeObserver(activationObserver) }
        accessibilityPoll?.cancel()
        activeTapCheck?.cancel()
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
        if isDownloadingModel, session.state == .idle {
            // F823: a press now would wait for the whole download — minutes on a slow link — with
            // the microphone's words held behind it. Refused before anything is recorded, and said
            // so, rather than listening and then making the user wait with no end in sight.
            log.notice("dictation press ignored — the dictation model is still downloading")
            flashBusy(.modelDownloading, announcing: Self.modelDownloadRefusal, for: 2.5)
            hotkeyMonitor.resetToggleState()
            return
        }
        switch session.handle(.startPressed) {
        case .startCapture:
            guard startCapture() else { return }
            prepareRefinerForCapture()
            prewarmEngineForCapture()
        case .busy:
            // A press arrived while a dictation is still in flight — leave the in-flight session
            // alone. Never reset it here; that would drop the pending transcript. Say so, though,
            // rather than swallowing the press (F443); the flash hands the pill back afterwards.
            // The monitor's toggle IS reset so the user's next press starts a fresh capture.
            log.notice("dictation press ignored — busy")
            flashBusy()
            hotkeyMonitor.resetToggleState()
        default:
            hotkeyMonitor.resetToggleState()
        }
    }

    private func handlePressEnd() {
        _ = beginTranscriptionIfNeeded()
    }

    /// The press that started this capture was half of a shortcut (F448): ⌘-Tab, ⌥-click, a
    /// character typed with Right ⌥. The user never meant to dictate, so the capture is dropped
    /// unheard — nothing is transcribed, pasted or logged — rather than finished. Only a capture
    /// still listening is dropped: a toggle-mode press that turned dictation OFF has already handed
    /// its audio to transcription, and that dictation is the user's.
    private func handlePressCancel() {
        guard enabled, session.state == .listening, recorder.isRecording else { return }
        log.notice("dictation cancelled — the trigger was part of a shortcut")
        captureWatchdog.cancel()
        recorder.cancel()
        _ = session.handle(.dismiss)
        status = settledStatus
        hideOverlay()
        // Toggle mode latched "on" at this press; the next press must start a dictation, not end one.
        hotkeyMonitor.resetToggleState()
        scheduleIdleEviction()
    }

    private func startCapture() -> Bool {
        do {
            dismissWorkItem?.cancel()
            busyHideWorkItem?.cancel()
            idleEvictWorkItem?.cancel() // fresh activity resets the idle-eviction clock
            // F357. Set before every start rather than once in `init`: the recorder is injected,
            // and a controller that claimed a callback it had not re-established after a swap
            // would fail exactly once, silently.
            recorder.onCaptureInterrupted = { [weak self] reason in
                Task { @MainActor [weak self] in self?.handleCaptureInterrupted(reason) }
            }
            try recorder.start { [weak self] level in
                Task { @MainActor [weak self] in self?.overlay.update(level: level) }
            }
            status = .listening
            showPhase(.listening)
            captureWatchdog.arm()
            // Where the key was pressed, which the paste is checked against (F445). Taken after the
            // microphone started: it asks the focused app over Accessibility, and a slow app must
            // not clip the first word. It also starts the off-main copy of the clipboard (F601).
            pressTarget = textInjector.captureWillStart(autoPaste: autoPaste)
            log.notice("listening")
            return true
        } catch {
            // F366: `error.localizedDescription` is the bridge's case-index sentence for anything
            // without copy of its own — `RecorderError` before it conformed, and every `NSError`
            // AVFAudio throws from `engine.start()` ("com.apple.coreaudio.avfaudio error -10851"),
            // which no conformance here can fix. The person sees a sentence; the code goes to the
            // diagnostic log, where the support question that follows will want it.
            let sentence = ErrorPresentation.sentence(
                for: error,
                fallback: "The microphone could not be started. Check that an input device is connected and selected in System Settings › Sound."
            )
            log.error("capture failed: \(ErrorPresentation.diagnostic(for: error), privacy: .public)")
            _ = session.handle(.engineFailed(sentence))
            hotkeyMonitor.resetToggleState() // capture never began — never leave toggle latched "on" (F38)
            fail(sentence)
            return false
        }
    }

    /// The audio hardware changed under a live capture, so the engine stopped itself (F357).
    ///
    /// Ends the session in a stated failure instead of leaving it in `.listening`, which is what
    /// it did before: the tap stopped delivering and nothing noticed, so the user kept talking and
    /// got a transcript of only the audio that preceded the change — or, if the change landed
    /// early, the "nothing heard" overlay. Silent truncation is worse than a visible failure
    /// because the user cannot tell it happened.
    ///
    /// The partial audio is discarded rather than transcribed. Pasting the first half of a
    /// sentence into whatever field has focus is the harm, not the remedy.
    @MainActor
    private func handleCaptureInterrupted(_ reason: DictationCaptureInterruption) {
        guard enabled, status == .listening else { return }
        log.error("dictation capture interrupted: \(String(describing: reason), privacy: .public)")
        captureWatchdog.cancel()
        recorder.cancel()
        _ = session.handle(.engineFailed(reason.message))
        // As the watchdog does: this ended without a user end-edge, so toggle mode's latched state
        // must be cleared or the next press fires a no-op end edge instead of a fresh start (F78).
        hotkeyMonitor.resetToggleState()
        fail(reason.message)
    }

    private func beginTranscriptionIfNeeded() -> Bool {
        captureWatchdog.cancel()
        guard recorder.isRecording else { return false }
        let clip: (url: URL, duration: TimeInterval)
        do {
            clip = try recorder.stop()
        } catch MicDictationRecorder.RecorderError.noAudioCaptured {
            // Genuinely nothing heard. Drive the machine out of .listening and release the mic
            // instead of wedging there forever; this is a normal no-op, not a failure.
            log.notice("dictation capture yielded no audio")
            recorder.cancel()
            _ = session.handle(.dismiss)
            status = settledStatus
            scheduleIdleEviction()
            showPhase(.empty)
            logStore.record(text: "", outcome: .empty)
            scheduleDismiss(after: 1.2)
            return false
        } catch {
            // Everything else is a failure and must not be reported as silence (F368). A converter
            // that refused every buffer produces the same empty sample array as a silent room, and
            // treating the two alike is what made that class of failure undiagnosable: the user saw
            // "nothing heard", the log recorded a normal empty result, and a support question had
            // no evidence to work from.
            let sentence = ErrorPresentation.sentence(
                for: error,
                fallback: "The dictation capture could not be completed."
            )
            log.error("dictation capture failed: \(ErrorPresentation.diagnostic(for: error), privacy: .public)")
            recorder.cancel()
            _ = session.handle(.engineFailed(sentence))
            hotkeyMonitor.resetToggleState()
            fail(sentence)
            return false
        }
        log.notice("clip \(clip.duration, format: .fixed(precision: 2))s")

        let action = session.handle(.endPressed(clipDuration: clip.duration))
        switch action {
        case .discard:
            try? FileManager.default.removeItem(at: clip.url)
            status = settledStatus
            scheduleIdleEviction() // a too-short tap still leaves the model warm — re-arm eviction
            hideOverlay()
            return true
        case .transcribe:
            status = .transcribing
            showPhase(.transcribing)
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
        // F821: the rules as they are when this dictation ended, like every other setting here.
        let rules = replacementRulesProvider()
        let ruleEvidence = rules.isEmpty
            ? CJKWordEvidence.none
            : CJKWordEvidence(segmenter: cjkWordSegmenter, knownTerms: knownTermsProvider())
        Task { [engine, log, refiner] in
            let started = Date()
            // F599: nothing loud enough to be speech goes to a model. The installed Whisper turbo
            // answers silence and quiet noise with "Thank you." and a no_speech_prob of ≈ 0, so the
            // helper's own skip (F449) never fires. Measured off the main actor; a clip the floor
            // cannot read is transcribed as before (`DictationSpeechFloor` errs that way).
            let level = await Task.detached { DictationSpeechFloor.level(ofClipAt: clip.url) }.value
            if let level, level.isBelowFloor {
                try? FileManager.default.removeItem(at: clip.url)
                log.notice("dictation clip below the speech floor (loudest 50 ms \(level.loudestWindowDBFS, format: .fixed(precision: 1)) dBFS); not transcribed")
                await MainActor.run { self.finish(text: "") }
                return
            }
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
                    await MainActor.run { if self.enabled { self.showPhase(.refining) } }
                    // F245: the whole vocabulary, not the prompt-capped slice and not gated on
                    // the engine's prompt support — this is a guard on the model's output, not a
                    // hint to the recognizer, and a term the user taught the app must survive
                    // whichever engine heard it.
                    let attempt = await refiner.attempt(
                        text: cleaned, languageCode: result.languageCode,
                        protectedTerms: vocabularyProvider())
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
                // F821: the user's replacement rules, last — on the refined text, or on the raw
                // text when refinement was off, skipped or refused — so a rule has the final say
                // over a model's spelling. Off the main actor: NLTokenizer segments the text, and a
                // 500-rule list is checked against it. The history keeps what was pasted in `text`
                // and, when refinement or a rule changed it, the recognizer's transcript in `rawText`.
                if !rules.isEmpty, !cleaned.isEmpty {
                    let recognized = rawText ?? cleaned
                    let beforeRules = cleaned
                    cleaned = await Task.detached {
                        ReplacementRuleMatcher.applied(rules, to: beforeRules, evidence: ruleEvidence)
                    }.value
                    if cleaned != beforeRules {
                        rawText = recognized
                        log.notice("replacement rules changed the dictation")
                    }
                }
                await MainActor.run {
                    self.finish(text: cleaned, rawText: rawText, refinement: refinement)
                }
            } catch {
                try? FileManager.default.removeItem(at: clip.url)
                // Raw here, sentence below (F366). `publicLogDescription` redacts paths, which a
                // transcription error can carry; `ErrorPresentation.diagnostic` adds the domain and
                // code for a framework error that carries neither a path nor any English.
                log.error("transcription failed: \(DiagnosticsBundleBuilder.publicLogDescription(error), privacy: .public) [\(ErrorPresentation.diagnostic(for: error), privacy: .public)]")
                let sentence = ErrorPresentation.sentence(
                    for: error,
                    fallback: "The transcription could not be completed."
                )
                await MainActor.run {
                    guard self.enabled else { return }
                    _ = self.session.handle(.engineFailed(sentence))
                    self.fail(sentence)
                }
            }
        }
    }

    private func finish(text: String, rawText: String? = nil, refinement: String? = nil) {
        guard enabled else { return } // feature was disabled mid-transcribe — drop the result, don't paste
        switch session.handle(.transcriptReady(text)) {
        case let .deliver(payload):
            status = .delivering
            let delivery = textInjector.deliver(payload, autoPaste: autoPaste, pressedIn: pressTarget)
            _ = session.handle(.delivered)
            switch delivery {
            case .pasted: showPhase(.done)
            // Pasted, and on the clipboard too: no "press ⌘V" notice, which would paste it twice (F600).
            case .pastedUnconfirmed: showPhase(.pastedUnconfirmed)
            case .clipboard: showPhase(.copied); clipboardNotifier()
            case .appChanged: showPhase(.appChanged); clipboardNotifier()
            // Not on the clipboard, so no notice: the pill's Copy button is the only way to it (F586).
            case .secureInput: showSecureCopyPill(.secureInput, holding: payload)
            case let .secureKeyboardEntry(app): showSecureCopyPill(.secureKeyboardEntry(app: app), holding: payload)
            }
            log.notice("delivered via \(String(describing: delivery), privacy: .public)")
            if delivery.isSecure {
                // Secure input means the words may be a password: kept out of the history file
                // (F445). Nothing is in flight any more — only the pill and its Copy button remain,
                // for longer than a result pill so there is time to reach it (F586).
                status = .idle
                scheduleDismiss(after: secureCopyWindow)
            } else {
                logStore.record(
                    text: payload,
                    outcome: delivery.wasPasted ? .pasted : .clipboard,
                    rawText: rawText,
                    refinement: refinement
                )
                scheduleDismiss(after: 1.1)
            }
        case .none where session.state == .failed(.emptyTranscript):
            showPhase(.empty)
            logStore.record(text: "", outcome: .empty)
            scheduleDismiss(after: 1.3)
            status = settledStatus
        default:
            scheduleDismiss(after: 1.0)
            status = settledStatus
        }
    }

    /// A refused press, said out loud: every refusal flashes, whether a meeting, a mic test or a
    /// model install holds the resources or a dictation is still in flight (F443). The flash never
    /// takes the pill over — when it ends, the pill goes back to `shownPhase`, or is hidden if
    /// nothing was showing — so a press during "Transcribing…" cannot leave that dictation without
    /// its pill. It uses its OWN work item so it can never cancel a pending session-resetting
    /// dismiss (which would leave the session wedged outside .idle).
    ///
    /// Announced once per flash (F537): more presses while it shows extend it silently. Putting the
    /// pill back afterwards is `overlay.show`, not `showPhase`, so whatever it restores is not
    /// announced a second time.
    ///
    /// A press refused because the model is still downloading (F823) flashes its own phase, for
    /// long enough to read, and says why.
    private func flashBusy(
        _ phase: DictationOverlay.Phase = .busy,
        announcing announcement: String? = nil,
        for seconds: TimeInterval = 0.8
    ) {
        // nil: the phase's own announcement.
        if !isFlashingBusy, let text = announcement ?? Self.announcement(for: phase) { announce(text) }
        overlay.show(phase)
        busyHideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Only the current flash's item runs: the next flash cancels this one before it can.
            self.busyHideWorkItem = nil
            if let phase = self.shownPhase { self.overlay.show(phase) } else { self.overlay.hide() }
        }
        busyHideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// What is said when a press is refused because the model is still downloading (F823).
    static let modelDownloadRefusal =
        "Dictation is not ready yet: its model is still downloading. That press was not used."

    /// The Dictation tab's and the menu's line while the model downloads (F823). The size is the
    /// pinned large-v3-turbo MLX weights F522 measured (1,613,977,612 bytes).
    static let modelDownloadNotice =
        "Downloading the dictation model (about 1.6 GB, once). Quick Dictation is ready when it finishes; until then a press is not used."

    /// The engine started or stopped downloading the model (F823). A dictation already waiting on
    /// it — its key was pressed before the download began — shows the download in its pill instead
    /// of "Transcribing…", and goes back to "Transcribing…" when the model is ready.
    private func modelDownloadChanged(_ downloading: Bool) {
        guard downloading != isDownloadingModel else { return }
        isDownloadingModel = downloading
        log.notice("dictation model download \(downloading ? "started" : "ended", privacy: .public)")
        guard enabled, status == .transcribing else { return }
        if downloading {
            showPhase(.modelDownloading)
        } else if shownPhase == .modelDownloading {
            showPhase(.transcribing)
        }
    }

    /// Shows a phase in the pill and, when it is an outcome, announces it (F537): the pill is a
    /// panel that never becomes key and hides within two seconds, which VoiceOver does not read.
    private func showPhase(_ phase: DictationOverlay.Phase, detail: String? = nil) {
        // The held text lives exactly as long as a pill that offers Copy (F586).
        if !phase.offersCopy { heldSecureDictation = nil }
        shownPhase = phase
        overlay.show(phase)
        if let text = Self.announcement(for: phase, detail: detail) { announce(text) }
    }

    private func showSecureCopyPill(_ phase: DictationOverlay.Phase, holding text: String) {
        showPhase(phase)
        heldSecureDictation = text
    }

    /// The pill's Copy button, for a dictation that was not pasted because of secure input (F586).
    /// The user's own act, so the text is written — concealed, by `copyConcealed` — and then no
    /// longer held. Nothing once the pill has gone.
    func copyHeldSecureDictation() {
        guard let text = heldSecureDictation, shownPhase?.offersCopy == true else { return }
        heldSecureDictation = nil
        textInjector.copyConcealed(text)
        showPhase(.copied)
        scheduleDismiss(after: 1.1)
    }

    private func hideOverlay() {
        heldSecureDictation = nil
        shownPhase = nil
        overlay.hide()
        // A dictation that ended without a paste leaves its clipboard copy unused (F601).
        textInjector.discardClipboardPrefetch()
    }

    private func fail(_ message: String) {
        status = .error(message)
        showPhase(.error, detail: message)
        logStore.record(text: "", outcome: .failed(message))
        scheduleDismiss(after: 1.6)
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        dismissWorkItem?.cancel()
        busyHideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideOverlay()
            _ = self.session.handle(.dismiss)
            self.status = self.settledStatus
            self.prewarmRefinerWhenSafe()
            self.scheduleIdleEviction()
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

    /// Speaks a dictation outcome to VoiceOver and other assistive apps (F537). Injectable, as
    /// `clipboardNotifier` is: tests record what would be said.
    var announce: (String) -> Void = DictationController.postAccessibilityAnnouncement

    /// NSAccessibilityConstants.h: the announcement notification "should be posted for the
    /// application element" and should carry a priority. High, because an outcome is only worth
    /// hearing as it happens. No application object (a headless process), nothing to post to.
    private static func postAccessibilityAnnouncement(_ text: String) {
        guard let app = NSApp else { return }
        NSAccessibility.post(
            element: app,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    /// What is announced for a pill phase (F537), or nil for progress: "Listening…" would be
    /// spoken into the microphone it names, and "Transcribing…" is followed within seconds by an
    /// outcome that is. `detail` is a failure's reason, which the pill itself never shows.
    static func announcement(for phase: DictationOverlay.Phase, detail: String? = nil) -> String? {
        switch phase {
        case .busy: "Dictation is busy. That press was not used."
        case .error: ["Dictation failed.", detail].compactMap { $0 }.joined(separator: " ")
        case .empty: "Dictation didn’t catch that."
        case .done: "Dictation pasted."
        case .pastedUnconfirmed: "Dictation pasted. It is also on the clipboard."
        case .copied: "Dictation copied to the clipboard."
        case .appChanged: "Dictation copied to the clipboard, because the app in front changed."
        // Not on the clipboard since F586: the pill offers Copy instead.
        case .secureInput: "Dictation not pasted, because a secure field has focus. Use Copy to copy it."
        case let .secureKeyboardEntry(app):
            "Dictation not pasted, because Secure Keyboard Entry is on in \(app). Use Copy to copy it."
        case .listening, .transcribing, .refining, .modelDownloading: nil
        }
    }

    private static func postClipboardNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Dictation copied"
        content.body = "Transcript is on the clipboard — press ⌘V to paste."
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Diagnostics / self-test

    /// `applicationSupport` is the runtime paths' own seam (the installers' and tests'): a test asks
    /// about a temporary library, never the user's.
    func diagnostics(applicationSupport: URL? = nil) -> DictationDiagnostics {
        let support = applicationSupport
        let files = FileManager.default
        let runtimeInstalled: Bool
        let helperInstalled: Bool
        let modelReady: Bool
        var modelRepairable = true
        switch selectedEngine {
        case .whisperTurbo:
            runtimeInstalled = files.isExecutableFile(
                atPath: LocalWhisperRuntime.pythonExecutable(applicationSupport: support).path
            )
            helperInstalled = files.fileExists(
                atPath: LocalWhisperRuntime.dictationServerScript(applicationSupport: support).path
            )
            (modelReady, modelRepairable) = Self.whisperTurboModelState(
                warmHelperRuns: warmWhisperHelperRunsHere,
                mlxModelCached: { LocalWhisperRuntime.mlxModelCached(applicationSupport: support) },
                checkpointCached: { LocalWhisperRuntime.checkpointCached(.turbo, applicationSupport: support) }
            )
        case .qwenBalanced:
            runtimeInstalled = QwenASRRuntime.isInstalled(applicationSupport: support)
            helperInstalled = files.fileExists(
                atPath: QwenASRRuntime.dictationHelperScript(applicationSupport: support).path
            )
            modelReady = files.fileExists(
                atPath: QwenASRRuntime.modelDirectory(applicationSupport: support)
                    .appendingPathComponent("model.safetensors").path
            )
        }
        return DictationDiagnostics(
            engineName: selectedEngine.displayName,
            runtimeInstalled: runtimeInstalled,
            helperInstalled: helperInstalled,
            modelReady: modelReady,
            modelRepairable: modelRepairable,
            microphoneGranted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            accessibilityGranted: HotkeyMonitor.isAccessibilityTrusted,
            hotkeyActive: hotkeyActive
        )
    }

    /// Whether the warm MLX helper can run on this Mac — Apple silicon (F823). Elsewhere
    /// `FallbackDictationEngine` runs openai-whisper's batch CLI instead. A seam so a test can ask
    /// what an Intel Mac's Dictation tab would say.
    var warmWhisperHelperRunsHere: Bool = {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }()

    /// The "Selected model ready" row for Whisper Turbo, and whether Repair can fix it (F823). With
    /// the warm helper, the model is the MLX weights, which Install / Repair fetches (F483).
    /// Without it, dictation runs the batch CLI's turbo checkpoint, which openai-whisper downloads
    /// on first use and no installer fetches — so Repair is never offered for it.
    static func whisperTurboModelState(
        warmHelperRuns: Bool,
        mlxModelCached: () -> Bool,
        checkpointCached: () -> Bool
    ) -> (ready: Bool, repairable: Bool) {
        warmHelperRuns ? (mlxModelCached(), true) : (checkpointCached(), false)
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
                message = "✗ \(ErrorPresentation.sentence(for: error, fallback: "\(engineName) did not respond."))"
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
        defaults.set(language.rawValue, forKey: Self.languageKey)
        defaults.set(autoPaste, forKey: Self.autoPasteKey)
        defaults.set(useVocabulary, forKey: Self.useVocabularyKey)
        defaults.set(refineEnabled, forKey: Self.refineEnabledKey)
        defaults.set(selectedEngine.rawValue, forKey: Self.engineKey)
    }

    /// Not part of `persist()`, and written only when the hotkey changed (F548). A newer build's
    /// mode reads here as hold, so re-saving the hotkey with every other setting replaced the
    /// user's stored choice with this build's fallback for it.
    private func persistHotkey() {
        defaults.set(try? JSONEncoder().encode(hotkey), forKey: Self.hotkeyKey)
    }
}
