import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

// F846 — a speech detector, not a level, before Whisper Turbo. F599's floor stops near-silence;
// louder noise still reached Whisper Turbo, which answered every one of lane K's 22 synthetic noise
// clips with invented text. The controller now asks FluidAudio's Silero VAD — shipped inside the app
// (the user's decision of 2026-10-07) — and a clip with no speech takes the "nothing heard" path.
// The controller tests script the detector; the bundle tests check the shipped model itself.

/// Answers every clip as the installed Whisper model answers noise.
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

/// Says what the test tells it, and counts the clips it was asked about.
private final class ScriptedDetector: DictationSpeechDetecting, @unchecked Sendable {
    private let lock = NSLock()
    private let peak: Float?
    private var asked = 0
    init(peak: Float?) { self.peak = peak }
    var calls: Int { lock.withLock { asked } }
    func peakSpeechProbability(ofClipAt url: URL) async -> Float? {
        lock.withLock { asked += 1 }
        return peak
    }
}

@MainActor
private final class PhaseLog: DictationOverlayPresenting {
    private(set) var shown: [DictationOverlay.Phase] = []
    func show(_ phase: DictationOverlay.Phase) { shown.append(phase) }
    func update(level: Float) {}
    func hide() {}
}

private let rate = Double(DictationCaptureLimits.sampleRate)

/// A 60 Hz hum at `dBFS` RMS for `seconds`.
private func hum(dBFS: Double, seconds: Double) -> [Float] {
    let amplitude = pow(10, dBFS / 20) * 2.squareRoot()
    return (0..<Int(saturating: seconds * rate)).map { Float(amplitude * sin(2 * .pi * 60 * Double($0) / rate)) }
}

@MainActor
private struct Harness {
    let controller: DictationController
    let monitor = FakeHotkeyMonitor()
    let engine = ThankYouEngine()
    let overlay = PhaseLog()
    let detector: ScriptedDetector
    let clip: URL
    let cleanUp: () -> Void

    /// `samples` is the capture, written where the fake recorder says the clip is. The default is
    /// loud enough to pass F599's level floor, so only the detector can stop it.
    init(peak: Float?, samples: [Float] = hum(dBFS: DictationSpeechFloor.floorDBFS + 20, seconds: 2)) throws {
        let suite = "WhisperMeet.DictationVoiceActivityGateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationVoiceActivityGateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanUp = {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set(true, forKey: "dictationEnabled")
        defaults.set(false, forKey: "dictationAutoPaste")
        clip = directory.appendingPathComponent("clip.wav")
        try WAVWriter.wavData(from: samples, sampleRate: DictationCaptureLimits.sampleRate).write(to: clip)
        let recorder = FakeDictationRecorder(outputURL: clip)
        recorder.stopDuration = Double(samples.count) / rate
        detector = ScriptedDetector(peak: peak)
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
        controller.speechDetector = detector
    }

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

@MainActor
@Test("A Whisper Turbo dictation the detector hears no speech in is not transcribed, pastes nothing, and is logged as nothing heard (F846)")
func aClipWithNoSpeechNeverReachesWhisper() async throws {
    let harness = try Harness(peak: 0.325) // the loudest noise clip measured
    defer { harness.cleanUp() }
    try #require(harness.controller.selectedEngine == .whisperTurbo)

    let entry = try await harness.dictate()

    #expect(harness.detector.calls == 1)
    #expect(harness.engine.transcribeCount == 0, "Whisper was asked, and answers noise with \"Thank you.\"")
    #expect(entry.outcome == .empty)
    #expect(entry.text.isEmpty)
    #expect(harness.overlay.shown.last == .empty, "the pill did not say nothing was heard")
    #expect(!FileManager.default.fileExists(atPath: harness.clip.path), "the clip was left on disk")
}

@MainActor
@Test("A clip with speech in it is transcribed and delivered as before (F846 control)")
func aClipWithSpeechIsTranscribed() async throws {
    let harness = try Harness(peak: 0.97)
    defer { harness.cleanUp() }

    let entry = try await harness.dictate()

    #expect(harness.detector.calls == 1)
    #expect(harness.engine.transcribeCount == 1)
    #expect(entry.outcome == .clipboard)
    #expect(entry.text == "Thank you.")
}

@MainActor
@Test("When the detector cannot tell — no model, a model that does not load — the clip is transcribed as before (F846)")
func anUndecidedClipFailsOpen() async throws {
    let harness = try Harness(peak: nil)
    defer { harness.cleanUp() }

    let entry = try await harness.dictate()

    #expect(harness.detector.calls == 1)
    #expect(harness.engine.transcribeCount == 1, "a detector that could not run refused the user's words")
    #expect(entry.text == "Thank you.")
}

@MainActor
@Test("A clip under F599's floor is stopped there, before the detector is asked (F846)")
func theLevelFloorRunsFirst() async throws {
    let harness = try Harness(peak: 0.97, samples: [Float](repeating: 0, count: Int(saturating: 2 * rate)))
    defer { harness.cleanUp() }

    let entry = try await harness.dictate()

    #expect(harness.detector.calls == 0)
    #expect(harness.engine.transcribeCount == 0)
    #expect(entry.outcome == .empty)
}

@Test("Only Whisper Turbo is gated, through the engine selection the dictation was made with (F846)")
func theGateIsTheSelectedEnginesOnly() throws {
    let code = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/Dictation/DictationController.swift")
    #expect(code.contains("let detector = DictationVoiceActivity.gates(selection) ? speechDetector : nil"))
    #expect(code.contains("var speechDetector: any DictationSpeechDetecting = SileroDictationSpeechDetector()"))
}

// MARK: - The model shipped in the app

private var shippedModel: URL {
    SourceAssertion.url("Resources/\(SileroDictationSpeechDetector.resourceDirectory)/\(SileroDictationSpeechDetector.modelName)")
}

@Test("The repository carries exactly the pinned Silero VAD files, each with its pinned SHA-256 (F846)")
func theShippedModelIsThePinnedOne() throws {
    #expect(SileroDictationSpeechDetector.modelVerifies(at: shippedModel))
    let enumerator = try #require(FileManager.default.enumerator(at: shippedModel, includingPropertiesForKeys: [.isRegularFileKey]))
    let base = shippedModel.standardizedFileURL.path + "/"
    let present = Set(enumerator.compactMap { $0 as? URL }
        .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        .map { $0.standardizedFileURL.path.replacingOccurrences(of: base, with: "") })
    let pinned = Set(SileroDictationSpeechDetector.pinnedFiles.map(\.path))
    #expect(present == pinned, "files not pinned: \(present.subtracting(pinned)); pinned but absent: \(pinned.subtracting(present))")
}

@Test("build-app.sh copies the model to where the detector looks, before signing, and the notices cover it (F846)")
func theModelIsBundledWhereTheDetectorLooks() throws {
    let build = try String(contentsOf: SourceAssertion.url("Scripts/build-app.sh"), encoding: .utf8)
    let directory = SileroDictationSpeechDetector.resourceDirectory
    let copy = try #require(build.range(
        of: #"cp -R "Resources/\#(directory)" "$app_dir/Contents/Resources/\#(directory)""#
    ), "build-app.sh does not copy the voice-activity model into the app")
    let clear = try #require(build.range(of: #"rm -rf "$app_dir/Contents/Resources/\#(directory)""#))
    let signing = try #require(build.range(of: "codesign --force"))
    #expect(clear.upperBound < copy.lowerBound, "a second build would nest the model inside the first copy")
    #expect(copy.upperBound < signing.lowerBound, "a resource copied after codesign invalidates the signature")

    // The detector resolves Contents/Resources/<directory>/<model> from the app bundle.
    let app = URL(fileURLWithPath: "/Applications/Example.app/Contents/Resources", isDirectory: true)
    let resolved = try #require(SileroDictationSpeechDetector.bundledModelURL(resourceURL: app))
    #expect(resolved.path == "/Applications/Example.app/Contents/Resources/\(directory)/\(SileroDictationSpeechDetector.modelName)")

    let notices = try String(contentsOf: SourceAssertion.url("Resources/THIRD-PARTY-NOTICES.txt"), encoding: .utf8)
    for required in [
        "Silero VAD", "https://github.com/snakers4/silero-vad", "FluidInference/silero-vad-coreml",
        "b419383c55c110e2c9271fa6ee0ea83d03c70d96", SileroDictationSpeechDetector.modelName,
        "Copyright (c) 2020-present Silero Team", "MIT License",
        "The above copyright notice and this permission notice shall be included in all",
    ] {
        #expect(notices.contains(required), "the notices file is missing \(required)")
    }
}

@Test("The shipped model loads and hears no speech in silence; a missing or altered model fails open (F846)")
func theShippedModelRunsAndFailsOpen() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("F846-model-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let silence = directory.appendingPathComponent("silence.wav")
    try WAVWriter.wavData(from: [Float](repeating: 0, count: Int(saturating: 3 * rate)), sampleRate: DictationCaptureLimits.sampleRate)
        .write(to: silence)

    let peak = try #require(await SileroDictationSpeechDetector(modelURL: shippedModel).peakSpeechProbability(ofClipAt: silence),
                            "the shipped model did not load or run")
    #expect(!DictationVoiceActivity.isSpeech(peakProbability: peak), "digital silence scored \(peak)")

    #expect(await SileroDictationSpeechDetector(modelURL: directory.appendingPathComponent("absent.mlmodelc"))
        .peakSpeechProbability(ofClipAt: silence) == nil)
    #expect(await SileroDictationSpeechDetector(modelURL: nil).peakSpeechProbability(ofClipAt: silence) == nil)

    let altered = directory.appendingPathComponent(SileroDictationSpeechDetector.modelName)
    try FileManager.default.copyItem(at: shippedModel, to: altered)
    let metadata = altered.appendingPathComponent("metadata.json")
    var bytes = try Data(contentsOf: metadata)
    bytes.append(0x20)
    try bytes.write(to: metadata)
    #expect(await SileroDictationSpeechDetector(modelURL: altered).peakSpeechProbability(ofClipAt: silence) == nil,
            "a model that does not match its pin was used")
}
