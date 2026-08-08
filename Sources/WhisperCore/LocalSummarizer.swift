import Foundation

/// Locates the on-device summarization runtime under
/// `~/Library/Application Support/WhisperMeet/Runtime/Summarizer/` and picks which model to install.
///
/// It is deliberately **separate** from `QwenASRRuntime`: local summaries are the *default*
/// summarizer (F164), so they must not require the opt-in Qwen3-ASR runtime to be installed. This
/// gives the summarizer its own `mlx_lm` venv, model, and helper, mirroring the Qwen layout.
public struct SummarizerRuntime: Sendable {
    /// Default on-device model on Macs with enough memory (Apache-2.0, ~4.5 GB, 4-bit, mlx_lm text).
    public static let defaultRepository = "mlx-community/Qwen3-8B-4bit"
    /// Fallback on memory-constrained Macs (Apache-2.0, ~2.3 GB, 4-bit).
    public static let fallbackRepository = "mlx-community/Qwen3-4B-4bit"
    /// Physical-RAM threshold for the larger default model: 16 GiB.
    public static let defaultModelMinimumBytes: UInt64 = 16 * 1024 * 1024 * 1024

    /// mlx runs only on Apple silicon, so on-device summaries are Apple-silicon only (like Qwen3-ASR).
    public static var isSupportedOnCurrentMac: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    public static func managedDirectory(applicationSupport: URL? = nil) -> URL {
        LocalWhisperRuntime.managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("Summarizer", isDirectory: true)
    }

    public static func pythonExecutable(applicationSupport: URL? = nil) -> URL {
        managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("venv/bin/python")
    }

    public static func helperScript(applicationSupport: URL? = nil) -> URL {
        managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("summarize_local.py")
    }

    /// The transcript-correction helper, installed alongside the summarizer in the same runtime (F165).
    public static func correctionHelperScript(applicationSupport: URL? = nil) -> URL {
        managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("correct_local.py")
    }

    public static func modelDirectory(applicationSupport: URL? = nil) -> URL {
        managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("model", isDirectory: true)
    }

    public static func isInstalled(applicationSupport: URL? = nil) -> Bool {
        let files = FileManager.default
        return files.isExecutableFile(atPath: pythonExecutable(
            applicationSupport: applicationSupport
        ).path)
            && files.fileExists(atPath: helperScript(
                applicationSupport: applicationSupport
            ).path)
            && files.fileExists(atPath: modelDirectory(
                applicationSupport: applicationSupport
            ).appendingPathComponent("model.safetensors").path)
    }

    /// Whether the runtime is installed AND carries the F165 correction helper. Kept separate from
    /// `isInstalled` so an F164-era summarizer install (which predates `correct_local.py`) still reports
    /// installed for summaries; correction just asks the user to update the model.
    public static func isCorrectionHelperInstalled(applicationSupport: URL? = nil) -> Bool {
        isInstalled(applicationSupport: applicationSupport)
            && FileManager.default.fileExists(
                atPath: correctionHelperScript(applicationSupport: applicationSupport).path
            )
    }

    /// The mlx-community repo to install, chosen by physical RAM: the 8B default on ≥16 GiB Macs, the
    /// 4B fallback below that. `physicalMemory` is injected (default `ProcessInfo.physicalMemory`) so
    /// the branch is unit-testable without specific hardware — the first RAM probe in the codebase.
    public static func recommendedRepository(
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> String {
        physicalMemory >= defaultModelMinimumBytes ? defaultRepository : fallbackRepository
    }
}

/// An on-device `MeetingSummarizer` backed by a local `mlx_lm` model via the `summarize_local.py`
/// helper (F164). It is the private, keyless default; `ClaudeSummarizer` remains the opt-in cloud
/// upgrade behind the same protocol. Spawn/stream/cancel mirror `QwenASRClient`.
public struct LocalSummarizer: MeetingSummarizer {
    private let pythonExecutableURL: URL
    private let helperScriptURL: URL
    private let modelDirectory: URL
    private let maxTokens: Int

    public init(
        pythonExecutableURL: URL = SummarizerRuntime.pythonExecutable(),
        helperScriptURL: URL = SummarizerRuntime.helperScript(),
        modelDirectory: URL = SummarizerRuntime.modelDirectory(),
        maxTokens: Int = 2_048
    ) {
        self.pythonExecutableURL = pythonExecutableURL
        self.helperScriptURL = helperScriptURL
        self.modelDirectory = modelDirectory
        self.maxTokens = maxTokens
    }

    public func summarize(
        transcript: String,
        language: String?,
        style: SummaryStyle,
        template: MeetingTemplate
    ) async throws -> MeetingSummary {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SummarizerError.emptyTranscript }
        guard runtimeIsComplete else { throw SummarizerError.modelNotInstalled }
        try Task.checkCancellation()

        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperMeet-Summary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let inputURL = workingDirectory.appendingPathComponent("request.json")
        let outputURL = workingDirectory.appendingPathComponent("summary.json")
        let requestBody: [String: String] = [
            "systemPrompt": Self.systemPrompt(language: language, style: style, template: template),
            "transcript": trimmed,
        ]
        try JSONSerialization.data(withJSONObject: requestBody).write(to: inputURL)

        let arguments = [
            helperScriptURL.path,
            "--model", modelDirectory.path,
            "--input", inputURL.path,
            "--output", outputURL.path,
            "--max-tokens", String(maxTokens),
        ]
        let log = try await run(arguments: arguments)
        try Task.checkCancellation()

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw SummarizerError.helperFailed(
                log.isEmpty ? "The local summarizer produced no output." : String(log.suffix(2_000))
            )
        }
        guard let payload = try? JSONDecoder().decode(
            LocalSummaryOutput.self,
            from: Data(contentsOf: outputURL)
        ) else {
            throw SummarizerError.unreadableResponse
        }
        let summary = MeetingSummary(
            summary: payload.summary,
            keyPoints: payload.keyPoints,
            // The local helper still emits action items as plain strings; F177 links each to its
            // supporting transcript moment later, in AppModel, from the meeting's segments.
            actionItems: payload.actionItems.map { ActionItem(text: $0) }
        )
        // A completely empty result is an error; a degraded raw-text summary (payload.warning set)
        // is still returned — a summary the user can read beats a dead end (honest fallback).
        guard !summary.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !summary.keyPoints.isEmpty
            || !summary.actionItems.isEmpty else {
            throw SummarizerError.emptyResponse
        }
        return summary
    }

    /// The local prompt reuses `ClaudeSummarizer.systemPrompt` verbatim — the single source of truth
    /// for the output fields and the do-not-translate clause — then appends an explicit JSON-format
    /// directive, because a local model has no enforced structured-output schema like Claude's.
    static func systemPrompt(
        language: String?,
        style: SummaryStyle,
        template: MeetingTemplate = .general
    ) -> String {
        ClaudeSummarizer.systemPrompt(language: language, style: style, template: template) + "\n" + jsonFormatInstruction
    }

    static let jsonFormatInstruction = """
    Respond with ONLY a JSON object with exactly these keys: "summary" (a string), "keyPoints" (an \
    array of strings), and "actionItems" (an array of strings). Do not write anything before or \
    after the JSON object, and do not wrap it in markdown code fences.
    """

    private var runtimeIsComplete: Bool {
        let files = FileManager.default
        return files.isExecutableFile(atPath: pythonExecutableURL.path)
            && files.fileExists(atPath: helperScriptURL.path)
            && files.fileExists(
                atPath: modelDirectory.appendingPathComponent("model.safetensors").path
            )
    }

    /// Keeps the model fully offline and unbuffered so its stderr progress streams live. Mirrors
    /// `QwenASRClient.makeEnvironment`.
    static func makeEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        return environment
    }

    /// Runs the helper, draining its merged stdout+stderr so no cooperative thread blocks on a full
    /// read and cancellation can terminate the child. The result is read from `--output`, not stdout
    /// (F24). Same streaming + `ProcessCancellationController` shape as `QwenASRClient.run`; the
    /// helper spawns no descendant processes, so terminating the child fully cancels it (unlike the
    /// transcription path's afconvert/ffmpeg descendants, still tracked by F153).
    private func run(arguments: [String]) async throws -> String {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = pythonExecutableURL
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        process.environment = Self.makeEnvironment()
        let cancellation = ProcessCancellationController(process: process)

        let handle = pipe.fileHandleForReading
        let processExited = armedExitStream(for: process)
        let dataStream = AsyncStream<Data> { continuation in
            handle.readabilityHandler = { fileHandle in
                let data = fileHandle.availableData
                if data.isEmpty {
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
            continuation.onTermination = { _ in
                handle.readabilityHandler = nil
            }
        }

        return try await withTaskCancellationHandler {
            try cancellation.runUnlessCancelled()

            var logData = Data()
            for await data in dataStream {
                logData.append(data)
                if logData.count > 200_000 {
                    logData = logData.suffix(100_000)
                }
            }
            // Wait for the child to exit via terminationHandler, not the blocking waitUntilExit()
            // (which wedges a Swift cooperative thread under load — see armedExitStream).
            for await _ in processExited {}
            handle.readabilityHandler = nil

            let log = String(decoding: logData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else {
                throw SummarizerError.helperFailed(
                    log.isEmpty
                        ? "The summarizer helper exited with status \(process.terminationStatus)."
                        : String(log.suffix(2_000))
                )
            }
            return log
        } onCancel: {
            cancellation.cancel()
        }
    }
}

/// The `summarize_local.py` `--output` payload. `warning`/`finishReason`/`generatedTokens` are
/// diagnostics; the three content fields decode straight into `MeetingSummary`.
struct LocalSummaryOutput: Decodable {
    let summary: String
    let keyPoints: [String]
    let actionItems: [String]
    let warning: String?
    let finishReason: String?
    let generatedTokens: Int?
}
