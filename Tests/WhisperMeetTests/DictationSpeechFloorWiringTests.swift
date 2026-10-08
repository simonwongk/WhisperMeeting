import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

/// F599 — a Quick Dictation with nothing said pasted "Thank you.": the installed large-v3-turbo
/// decodes that from digital silence and from every synthetic noise clip measured, with a
/// `no_speech_prob` of ≈ 0, so F449's skip inside the helper never fires. The controller now
/// measures the clip itself (`DictationSpeechFloor`) before any model is asked. Driven through the
/// real controller with the recorder faked and a real WAV at the clip's path, so the gate reads
/// the file exactly as it reads a real capture.

/// Answers every clip as the installed Whisper model answers silence.
private final class ThankYouEngine: DictationEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var transcribeCount: Int { lock.withLock { calls } }

    func warmUp() async throws {}
    func transcribe(wavAt url: URL, language: WhisperLanguage, initialPrompt: String?) async throws -> DictationResult {
        lock.withLock { calls += 1 }
        return DictationResult(text: "Thank you.", languageCode: "en")
    }
    func shutdown() {}
}

@MainActor
private final class PhaseLog: DictationOverlayPresenting {
    private(set) var shown: [DictationOverlay.Phase] = []
    func show(_ phase: DictationOverlay.Phase) { shown.append(phase) }
    func update(level: Float) {}
    func hide() {}
}

@MainActor
private struct Harness {
    let controller: DictationController
    let monitor: FakeHotkeyMonitor
    let engine = ThankYouEngine()
    let overlay = PhaseLog()
    let clip: URL
    let cleanUp: () -> Void

    /// `samples` is what the microphone captured; it is written where the fake recorder says the
    /// clip is, in the recorder's own format.
    init(samples: [Float]) throws {
        let suite = testSuiteName()
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationSpeechFloorWiringTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanUp = {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set(true, forKey: "dictationEnabled")
        defaults.set(false, forKey: "dictationAutoPaste")
        clip = directory.appendingPathComponent("clip.wav")
        try WAVWriter.wavData(from: samples, sampleRate: DictationCaptureLimits.sampleRate).write(to: clip)
        monitor = FakeHotkeyMonitor()
        let recorder = FakeDictationRecorder(outputURL: clip)
        recorder.stopDuration = Double(samples.count) / Double(DictationCaptureLimits.sampleRate)
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
        controller.clipboardNotifier = {} // UNUserNotificationCenter crashes without an app bundle
    }

    /// One press and release; returns once the dictation's outcome is in the log.
    func dictate() async throws -> DictationLogEntry {
        monitor.onPressStart?()
        try #require(controller.status == .listening)
        monitor.onPressEnd?()
        let deadline = ContinuousClock.now + .seconds(30)
        while controller.logStore.log.entries.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        return try #require(controller.logStore.log.entries.first, "the dictation never finished")
    }
}

private func seconds(_ value: Double) -> Int { Int(saturating: value * Double(DictationCaptureLimits.sampleRate)) }

/// A 60 Hz hum at `dBFS` RMS: a quiet room's mains hum, deterministic.
private func hum(dBFS: Double, seconds duration: Double) -> [Float] {
    let amplitude = pow(10, dBFS / 20) * 2.squareRoot()
    let rate = Double(DictationCaptureLimits.sampleRate)
    return (0..<seconds(duration)).map { Float(amplitude * sin(2 * .pi * 60 * Double($0) / rate)) }
}

@MainActor
@Test("A dictation with nothing said is not sent to the model, pastes nothing, and is logged as nothing heard (F599)")
func aSilentDictationIsNeverTranscribed() async throws {
    let captures: [(String, [Float])] = [
        ("digital silence", [Float](repeating: 0, count: seconds(3))),
        ("a quiet room's hum", hum(dBFS: DictationSpeechFloor.floorDBFS - 10, seconds: 3)),
    ]
    for (name, samples) in captures {
        let harness = try Harness(samples: samples)
        defer { harness.cleanUp() }

        let entry = try await harness.dictate()

        #expect(harness.engine.transcribeCount == 0, "\(name): the model was asked, and answers \"Thank you.\"")
        #expect(entry.outcome == .empty, "\(name): logged as \(entry.outcome), not as nothing heard")
        #expect(entry.text.isEmpty, "\(name): \"\(entry.text)\" was delivered")
        #expect(harness.overlay.shown.last == .empty, "\(name): the pill did not say nothing was heard")
        #expect(!FileManager.default.fileExists(atPath: harness.clip.path), "\(name): the clip was left on disk")
    }
}

@MainActor
@Test("A clip that reaches the floor still goes to the model and is delivered (F599 control)")
func aClipAboveTheFloorIsTranscribed() async throws {
    // Half a second of a quiet voice-level signal inside a held key: over the floor only in its
    // loudest window.
    let samples = [Float](repeating: 0, count: seconds(1))
        + hum(dBFS: DictationSpeechFloor.floorDBFS + 10, seconds: 0.5)
        + [Float](repeating: 0, count: seconds(1))
    let harness = try Harness(samples: samples)
    defer { harness.cleanUp() }

    let entry = try await harness.dictate()

    #expect(harness.engine.transcribeCount == 1)
    #expect(entry.outcome == .clipboard)
    #expect(entry.text == "Thank you.")
}
