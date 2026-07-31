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

    var isAccessibilityTrusted: Bool { HotkeyMonitor.isAccessibilityTrusted }
    func requestAccessibility() { HotkeyMonitor.requestAccessibility() }

    /// True while dictation owns the microphone/result path or is retiring a resident model. Used by
    /// `AppModel` to avoid microphone and large-model contention with meeting recording.
    var isActive: Bool {
        if isSwitchingModel { return true }
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
    private let engineFactory: (DictationTranscriptionEngine) -> DictationEngine
    private let captureTimeout: Duration
    private let captureSleep: DictationCaptureWatchdog.Sleep
    private var session = DictationSession()
    private var isMicrophoneBusy: () -> Bool = { false }
    private var vocabularyProvider: () -> [String] = { [] }
    private var dismissWorkItem: DispatchWorkItem?
    private var busyHideWorkItem: DispatchWorkItem?
    private var idleEvictWorkItem: DispatchWorkItem?
    private var hotkeyActive = false
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

    private static let idleEvictSeconds: TimeInterval = 300 // 5 min; configurable later

    private static let enabledKey = "dictationEnabled"
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
        activateOnInit: Bool = true
    ) {
        self.defaults = defaults
        self.recorder = recorder
        self.overlay = overlay ?? DictationOverlay()
        self.hotkeyMonitor = hotkeyMonitor
        self.logStore = logStore ?? DictationLogStore()
        self.captureTimeout = captureTimeout
        self.captureSleep = captureSleep
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

    func warmUpIfNeeded() {
        guard enabled else { return }
        log.notice("warm-up starting for \(self.selectedEngine.rawValue, privacy: .public)")
        Task { [engine, log] in
            do {
                try await engine.warmUp()
                await MainActor.run { self.scheduleIdleEviction() } // warmed but no dictation yet — still evict if unused
            } catch {
                log.error("warm-up failed: \(error.localizedDescription, privacy: .public)")
            }
        }
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
            engine.shutdown()             // release the resident model/subprocess when disabled
            status = .disabled
            log.notice("dictation disabled")
        }
    }

    /// Keep the selected model's installed helper in sync with this app build. This self-heals an
    /// existing runtime that predates Qwen dictation as well as applying future protocol fixes.
    private func ensureHelperInstalled() {
        let resource: String
        let python: URL
        let script: URL
        switch selectedEngine {
        case .whisperTurbo:
            resource = "whisper_dictate_server"
            python = LocalWhisperRuntime.pythonExecutable()
            script = LocalWhisperRuntime.dictationServerScript()
        case .qwenBalanced:
            resource = "qwen_dictate_server"
            python = QwenASRRuntime.pythonExecutable()
            script = QwenASRRuntime.dictationHelperScript()
        }
        guard FileManager.default.fileExists(atPath: python.path) else { return } // no runtime installed yet
        guard let bundled = Bundle.main.url(forResource: resource, withExtension: "py"),
              let bundledData = try? Data(contentsOf: bundled) else {
            if !FileManager.default.fileExists(atPath: script.path) {
                log.error("\(resource, privacy: .public) missing and no bundled copy found")
            }
            return
        }
        let installedData = try? Data(contentsOf: script)
        guard bundledData != installedData else { return } // already the current version
        do {
            try FileManager.default.createDirectory(
                at: script.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try bundledData.write(to: script)
            log.notice("\(resource, privacy: .public) synced from app bundle into runtime")
        } catch {
            log.error("failed to install dictation helper: \(error.localizedDescription, privacy: .public)")
        }
    }

    deinit {
        hotkeyMonitor.stop()
        engine.shutdown()
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
        switch session.handle(.startPressed) {
        case .startCapture: startCapture()
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
            log.notice("dictation capture yielded no audio: \(error.localizedDescription, privacy: .public)")
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
        Task { [engine, log] in
            let started = Date()
            do {
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
                await MainActor.run { self.finish(text: cleaned) }
            } catch {
                try? FileManager.default.removeItem(at: clip.url)
                log.error("transcription failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    guard self.enabled else { return }
                    _ = self.session.handle(.engineFailed(error.localizedDescription))
                    self.fail(error.localizedDescription)
                }
            }
        }
    }

    private func finish(text: String) {
        guard enabled else { return } // feature was disabled mid-transcribe — drop the result, don't paste
        switch session.handle(.transcriptReady(text)) {
        case let .deliver(payload):
            status = .delivering
            let delivery = autoPaste ? TextInjector.deliver(payload) : deliverClipboardOnly(payload)
            _ = session.handle(.delivered)
            switch delivery {
            case .pasted: overlay.show(.done)
            case .clipboard: overlay.show(.copied); notifyClipboard()
            }
            log.notice("delivered via \(delivery == .pasted ? "paste" : "clipboard", privacy: .public)")
            logStore.record(text: payload, outcome: delivery == .pasted ? .pasted : .clipboard)
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
            self.engine.shutdown()
        }
        idleEvictWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleEvictSeconds, execute: item)
    }


    private func notifyClipboard() {
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
        defaults.set(selectedEngine.rawValue, forKey: Self.engineKey)
    }
}
