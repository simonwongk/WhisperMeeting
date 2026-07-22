// Sources/WhisperMeet/Dictation/DictationController.swift
import AppKit
import Foundation
import UserNotifications
import WhisperCore
import os

/// Owns the quick-dictation feature end to end: hotkey → capture → warm Whisper → paste, driven by
/// the pure `DictationSession`. Independent of the meeting pipeline; disabled while a meeting records.
@MainActor
final class DictationController: ObservableObject {
    enum Status: Equatable {
        case disabled, idle, listening, transcribing, delivering
        case error(String)
    }

    @Published private(set) var status: Status = .disabled
    @Published var enabled: Bool { didSet { persist(); apply() } }
    @Published var hotkey: DictationHotkey { didSet { persist(); if enabled { _ = hotkeyMonitor.start(hotkey: hotkey) } } }
    @Published var language: WhisperLanguage { didSet { persist() } }
    @Published var autoPaste: Bool { didSet { persist() } }

    var isAccessibilityTrusted: Bool { HotkeyMonitor.isAccessibilityTrusted }
    func requestAccessibility() { HotkeyMonitor.requestAccessibility() }

    private let defaults: UserDefaults
    private let hotkeyMonitor = HotkeyMonitor()
    private let recorder = MicDictationRecorder()
    private let overlay = DictationOverlay()
    private let engine: DictationEngine
    private var session = DictationSession()
    private var isMeetingActive: () -> Bool = { false }
    private var dismissWorkItem: DispatchWorkItem?
    private let log = Logger(subsystem: "com.whispermeet.app", category: "dictation")

    private static let enabledKey = "dictationEnabled"
    private static let hotkeyKey = "dictationHotkey"
    private static let languageKey = "dictationLanguage"
    private static let autoPasteKey = "dictationAutoPaste"

    init(defaults: UserDefaults = .standard, engine: DictationEngine? = nil) {
        self.defaults = defaults
        self.engine = engine ?? DictationController.makeDefaultEngine()
        enabled = defaults.bool(forKey: Self.enabledKey)
        hotkey = (try? JSONDecoder().decode(DictationHotkey.self, from: defaults.data(forKey: Self.hotkeyKey) ?? Data())) ?? .rightOption
        language = WhisperLanguage(rawValue: defaults.string(forKey: Self.languageKey) ?? "") ?? .automatic
        autoPaste = defaults.object(forKey: Self.autoPasteKey) as? Bool ?? true

        hotkeyMonitor.onPressStart = { [weak self] in self?.handlePressStart() }
        hotkeyMonitor.onPressEnd = { [weak self] in self?.handlePressEnd() }
        apply()
    }

    private static func makeDefaultEngine() -> DictationEngine {
        let python = LocalWhisperRuntime.pythonExecutable()
        let script = LocalWhisperRuntime.dictationServerScript()
        let models = LocalWhisperRuntime.modelDirectory()
        return WarmWhisperDictationEngine(python: python, script: script, modelDirectory: models, model: .turbo)
    }

    func configure(isMeetingActive: @escaping () -> Bool) {
        self.isMeetingActive = isMeetingActive
    }

    func setEnabled(_ on: Bool) { enabled = on }

    func warmUpIfNeeded() {
        guard enabled else { return }
        Task.detached { [engine, log] in
            do { try await engine.warmUp() } catch { log.error("warm-up failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    // MARK: - Enable / disable

    private func apply() {
        if enabled {
            let started = hotkeyMonitor.start(hotkey: hotkey)
            status = .idle
            if !started {
                log.error("event tap could not be created — Accessibility/Input Monitoring off")
                status = .error("Enable Accessibility for WhisperMeet in System Settings.")
            }
            Task { await requestMicIfNeeded() }
            warmUpIfNeeded()
        } else {
            hotkeyMonitor.stop()
            overlay.hide()
            status = .disabled
        }
    }

    private func requestMicIfNeeded() async {
        _ = await recorder.requestPermission()
    }

    // MARK: - Hotkey events

    private func handlePressStart() {
        guard enabled else { return }
        if isMeetingActive() {
            log.notice("dictation press ignored — meeting recording active")
            flashBusy()
            return
        }
        switch session.handle(.startPressed) {
        case .startCapture: startCapture()
        case .busy: flashBusy()
        default: break
        }
    }

    private func handlePressEnd() {
        guard case .listening = statusMirror() else {
            // still handle to keep the machine honest
            _ = beginTranscriptionIfNeeded()
            return
        }
        _ = beginTranscriptionIfNeeded()
    }

    private func statusMirror() -> DictationSession.State { session.state }

    private func startCapture() {
        do {
            dismissWorkItem?.cancel()
            try recorder.start { [weak self] level in
                Task { @MainActor [weak self] in self?.overlay.update(level: level) }
            }
            status = .listening
            overlay.show(.listening)
            log.notice("listening")
        } catch {
            _ = session.handle(.engineFailed(error.localizedDescription))
            fail(error.localizedDescription)
        }
    }

    private func beginTranscriptionIfNeeded() -> Bool {
        let clip: (url: URL, duration: TimeInterval)
        do { clip = try recorder.stop() }
        catch { return false }

        let action = session.handle(.endPressed(clipDuration: clip.duration))
        switch action {
        case .discard:
            try? FileManager.default.removeItem(at: clip.url)
            status = .idle
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
        Task { [engine, log] in
            let started = Date()
            do {
                let result = try await engine.transcribe(wavAt: clip.url, language: language, initialPrompt: nil)
                try? FileManager.default.removeItem(at: clip.url)
                let cleaned = DictationTextCleanup.clean(result.text)
                log.notice("transcribed in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
                await MainActor.run { self.finish(text: cleaned) }
            } catch {
                try? FileManager.default.removeItem(at: clip.url)
                log.error("transcription failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    _ = self.session.handle(.engineFailed(error.localizedDescription))
                    self.fail(error.localizedDescription)
                }
            }
        }
    }

    private func finish(text: String) {
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
            scheduleDismiss(after: 1.1)
        case .none where session.state == .failed(.emptyTranscript):
            overlay.show(.empty)
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
        overlay.show(.busy)
        scheduleDismiss(after: 0.8)
    }

    private func fail(_ message: String) {
        status = .error(message)
        overlay.show(.error)
        scheduleDismiss(after: 1.6)
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        dismissWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.overlay.hide()
            _ = self?.session.handle(.dismiss)
            self?.status = .idle
        }
        dismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func notifyClipboard() {
        let content = UNMutableNotificationContent()
        content.title = "Dictation copied"
        content.body = "Transcript is on the clipboard — press ⌘V to paste."
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func persist() {
        defaults.set(enabled, forKey: Self.enabledKey)
        defaults.set(try? JSONEncoder().encode(hotkey), forKey: Self.hotkeyKey)
        defaults.set(language.rawValue, forKey: Self.languageKey)
        defaults.set(autoPaste, forKey: Self.autoPasteKey)
    }
}
