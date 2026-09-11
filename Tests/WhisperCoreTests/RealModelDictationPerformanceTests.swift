import Foundation
import Testing
@testable import WhisperCore

/// F206 — the real-installed-model half of the dictation speed work.
///
/// Everything else in this suite drives fake line-servers, which is right for protocol and
/// lifecycle rules but cannot measure latency or catch upstream drift in `mlx_whisper` / `mlx_lm`.
/// These cases spawn the **installed** helpers with the exact argv production uses
/// (`DictationController.makeEngine` / the `WarmRefineEngine` construction beside it) and read only
/// `Scripts/bench/clips`, never a user recording.
///
/// Opt-in, because each case loads multi-gigabyte weights and takes tens of seconds:
///
/// ```
/// WHISPERMEET_REAL_MODEL_PERF=1 swift test --disable-sandbox --no-parallel \
///   --filter RealModelDictation
/// ```
///
/// The measurements print to stderr via `recordTiming`; the assertions are deliberately loose
/// (order-of-magnitude ceilings, not machine-specific numbers) so this can fail red on a genuine
/// regression without failing on an unrelated machine being slower.
private enum RealModelPerf {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["WHISPERMEET_REAL_MODEL_PERF"] == "1"
    }

    /// The bench clips live beside the sources, not in a bundle resource, so walk up from this file.
    static var clipsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhisperCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Scripts/bench/clips", isDirectory: true)
    }

    static func clip(_ name: String) -> URL {
        clipsDirectory.appendingPathComponent(name)
    }

    static var recognitionRuntimeReady: Bool {
        let files = FileManager.default
        return files.isExecutableFile(atPath: LocalWhisperRuntime.pythonExecutable().path)
            && files.fileExists(atPath: LocalWhisperRuntime.dictationServerScript().path)
            && LocalWhisperRuntime.mlxModelCached()
    }

    static var refineRuntimeReady: Bool {
        let files = FileManager.default
        return files.isExecutableFile(atPath: SummarizerRuntime.pythonExecutable().path)
            && files.fileExists(atPath: SummarizerRuntime.refineHelperScript().path)
            && files.fileExists(atPath: SummarizerRuntime.modelDirectory().path)
    }

    static func productionRecognitionEngine() -> WarmWhisperDictationEngine {
        WarmWhisperDictationEngine(
            python: LocalWhisperRuntime.pythonExecutable(),
            script: LocalWhisperRuntime.dictationServerScript(),
            modelDirectory: LocalWhisperRuntime.modelDirectory()
        )
    }

    static func productionRefineEngine() -> WarmRefineEngine {
        WarmRefineEngine(
            python: SummarizerRuntime.pythonExecutable(),
            script: SummarizerRuntime.refineHelperScript(),
            modelDirectory: SummarizerRuntime.modelDirectory(),
            primePrompt: DictationRefinePrompt.system(languageCode: nil)
        )
    }

    /// Measured elapsed seconds for `body`, printed with a label so an opt-in run leaves a record.
    static func measure(_ label: String, _ body: () async throws -> Void) async rethrows -> Double {
        let start = ContinuousClock.now
        try await body()
        let elapsed = ContinuousClock.now - start
        let value = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        FileHandle.standardError.write(
            Data("    [real-model] \(label): \(String(format: "%.2f", value))s\n".utf8)
        )
        return value
    }
}

@Test(
    "Real installed MLX recognition helper transcribes a bench clip through the production engine (F206)",
    .enabled(if: RealModelPerf.isEnabled && RealModelPerf.recognitionRuntimeReady)
)
func realModelDictationRecognitionTranscribesBenchClip() async throws {
    let engine = RealModelPerf.productionRecognitionEngine()
    defer { engine.shutdown() }

    let coldReady = try await RealModelPerf.measure("recognition cold warm-up") {
        try await engine.warmUp()
    }

    var texts: [String] = []
    let clips = ["en1.wav", "en2.wav", "zh1.wav"]
    var warmLatencies: [Double] = []
    for clip in clips {
        let latency = try await RealModelPerf.measure("transcribe \(clip) (warm)") {
            let result = try await engine.transcribe(
                wavAt: RealModelPerf.clip(clip),
                language: .automatic,
                initialPrompt: nil
            )
            texts.append(result.text)
        }
        warmLatencies.append(latency)
    }

    // The point of the resident helper: a warm request must not pay the model load again. The
    // ceiling is the cold warm-up itself, which is the cost this design exists to amortize.
    for latency in warmLatencies {
        #expect(latency < coldReady)
    }
    // Real transcription, not an empty stub reply.
    #expect(texts.allSatisfy { !$0.isEmpty })
}

@Test(
    "Real installed recognition helper releases promptly when a meeting claims memory (F206)",
    .enabled(if: RealModelPerf.isEnabled && RealModelPerf.recognitionRuntimeReady)
)
func realModelDictationEvictionReleasesPromptly() async throws {
    let engine = RealModelPerf.productionRecognitionEngine()
    defer { engine.shutdown() }
    try await engine.warmUp()
    // One real request first, so the helper has actually spawned its `ffmpeg` child at least once —
    // the descendant shape the process-group escalation exists for.
    _ = try await engine.transcribe(
        wavAt: RealModelPerf.clip("en1.wav"),
        language: .automatic,
        initialPrompt: nil
    )

    let released = await RealModelPerf.measure("evict a warm real helper") {
        await engine.evict()
    }
    // A cooperative helper exits on stdin close, well inside the 5s SIGKILL escalation window. If
    // this ever needs the escalation, the graceful path has regressed.
    #expect(released < 5.0)

    // The engine must still be usable afterwards — eviction is temporary, not a retirement.
    let rewarmed = try await RealModelPerf.measure("re-warm after eviction") {
        try await engine.warmUp()
    }
    #expect(rewarmed > 0)
}

@Test(
    "Real 4B/8B refine model loading beside recognition is the contention F206 removes (F206)",
    .enabled(
        if: RealModelPerf.isEnabled
            && RealModelPerf.recognitionRuntimeReady
            && RealModelPerf.refineRuntimeReady
    )
)
func realModelRecognitionUnderRefinerColdLoadIsSlower() async throws {
    let recognition = RealModelPerf.productionRecognitionEngine()
    defer { recognition.shutdown() }
    try await recognition.warmUp()

    // Baseline: the shape the app now guarantees — recognition alone in unified memory.
    var solo: [Double] = []
    for clip in ["en1.wav", "en2.wav", "en3.wav"] {
        solo.append(
            try await RealModelPerf.measure("solo transcribe \(clip)") {
                _ = try await recognition.transcribe(
                    wavAt: RealModelPerf.clip(clip), language: .automatic, initialPrompt: nil
                )
            }
        )
    }

    // The pre-fix shape: the optional polish model cold-loading while recognition runs.
    let refiner = RealModelPerf.productionRefineEngine()
    defer { refiner.shutdown() }
    let refinerWarm = Task { try? await refiner.warmUp() }
    var contended: [Double] = []
    for clip in ["en1.wav", "en2.wav", "en3.wav"] {
        contended.append(
            try await RealModelPerf.measure("transcribe \(clip) under refiner cold load") {
                _ = try await recognition.transcribe(
                    wavAt: RealModelPerf.clip(clip), language: .automatic, initialPrompt: nil
                )
            }
        )
    }
    _ = await refinerWarm.value
    await refiner.evict()

    let soloMean = solo.reduce(0, +) / Double(solo.count)
    let contendedMean = contended.reduce(0, +) / Double(contended.count)
    FileHandle.standardError.write(
        Data(
            """
                [real-model] solo mean \(String(format: "%.2f", soloMean))s vs contended mean \
            \(String(format: "%.2f", contendedMean))s (ratio \
            \(String(format: "%.2fx", contendedMean / max(soloMean, 0.001))))

            """.utf8
        )
    )
    // This is the measured premise of the whole fix. If contention ever stops costing anything on
    // this class of machine, the release/admission machinery guarding against it is dead weight and
    // this case should fail so someone re-reads that conclusion rather than inheriting it.
    #expect(contendedMean > soloMean)
}
