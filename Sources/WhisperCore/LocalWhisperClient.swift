import Foundation

public enum LocalWhisperError: LocalizedError, Sendable, Equatable {
    case runtimeNotInstalled
    case recordingNotFound
    case processFailed(String)
    case missingOutput
    case unreadableOutput
    case emptyTranscript

    public var errorDescription: String? {
        switch self {
        case .runtimeNotInstalled:
            return "Local Whisper is not installed. Open Settings and choose Install Local Whisper."
        case .recordingNotFound:
            return "The meeting recording could not be found."
        case let .processFailed(message):
            return "Local transcription failed: \(message)"
        case .missingOutput:
            return "Local Whisper finished without creating a transcript."
        case .unreadableOutput:
            return "Local Whisper created a transcript that the app could not read."
        case .emptyTranscript:
            return "No speech was detected in the recording."
        }
    }
}

public struct LocalWhisperRuntime: Sendable {
    public static func managedDirectory(applicationSupport: URL? = nil) -> URL {
        let support = applicationSupport ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return support
            .appendingPathComponent("WhisperMeet", isDirectory: true)
            .appendingPathComponent("Runtime", isDirectory: true)
    }

    public static func managedExecutable(applicationSupport: URL? = nil) -> URL {
        managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("venv/bin/whisper")
    }

    public static func modelDirectory(applicationSupport: URL? = nil) -> URL {
        let support = applicationSupport ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return support
            .appendingPathComponent("WhisperMeet", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    public static func findExecutable(applicationSupport: URL? = nil) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            managedExecutable(applicationSupport: applicationSupport),
            URL(fileURLWithPath: "/opt/homebrew/bin/whisper"),
            URL(fileURLWithPath: "/usr/local/bin/whisper"),
            home.appendingPathComponent(".local/bin/whisper")
        ]
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    public static func pythonExecutable(applicationSupport: URL? = nil) -> URL {
        managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("venv/bin/python")
    }

    /// Whether the MLX dictation model's weights are actually present in the local Hugging Face
    /// cache. huggingface_hub creates the `models--org--repo` tree at the START of a download, so
    /// the directory existing doesn't mean the model is usable — we require a snapshot that carries
    /// both `weights.safetensors` and `config.json` (matching the helper's completeness check).
    public static func mlxModelCached(
        applicationSupport: URL? = nil,
        mlxRepo: String = "mlx-community/whisper-large-v3-turbo"
    ) -> Bool {
        let repoFolder = "models--" + mlxRepo.replacingOccurrences(of: "/", with: "--")
        let snapshots = modelDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("hf/hub", isDirectory: true)
            .appendingPathComponent(repoFolder, isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: snapshots,
            includingPropertiesForKeys: nil
        ) else {
            return false
        }
        return entries.contains { snapshot in
            FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("weights.safetensors").path)
                && FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("config.json").path)
        }
    }

    public static func dictationServerScript(applicationSupport: URL? = nil) -> URL {
        managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("whisper_dictate_server.py")
    }
}

public struct LocalWhisperClient: Sendable {
    public typealias ProgressHandler = @Sendable (LocalTranscriptionProgress) async -> Void

    private let executableURL: URL
    private let modelDirectory: URL

    public init(executableURL: URL, modelDirectory: URL) {
        self.executableURL = executableURL
        self.modelDirectory = modelDirectory
    }

    public func transcribe(
        recordingAt fileURL: URL,
        options: LocalTranscriptionOptions = .accuracyFirst(),
        onProgress: @escaping ProgressHandler = { _ in }
    ) async throws -> TranscriptionResult {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw LocalWhisperError.runtimeNotInstalled
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw LocalWhisperError.recordingNotFound
        }
        try Task.checkCancellation()

        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperMeet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        await onProgress(.preparing)
        let arguments = commandArguments(
            recordingAt: fileURL,
            outputDirectory: workingDirectory,
            options: options
        )
        // Whisper loads (and on first use downloads) the model before it transcribes; the parser
        // upgrades the phase as soon as the CLI starts reporting a progress bar.
        await onProgress(.loadingModel)
        let log = try await run(
            arguments: arguments,
            workingDirectory: workingDirectory,
            onProgress: onProgress
        )
        try Task.checkCancellation()

        let outputURL = workingDirectory
            .appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            if !log.isEmpty { throw LocalWhisperError.processFailed(log) }
            throw LocalWhisperError.missingOutput
        }
        guard let payload = try? JSONDecoder().decode(
            WhisperOutput.self,
            from: Data(contentsOf: outputURL)
        ) else {
            throw LocalWhisperError.unreadableOutput
        }

        let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LocalWhisperError.emptyTranscript }
        let segments = payload.segments.compactMap { segment -> TranscriptSegment? in
            let segmentText = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !segmentText.isEmpty else { return nil }
            return TranscriptSegment(
                speaker: nil,
                start: segment.start,
                end: segment.end,
                text: segmentText,
                avgLogprob: segment.avgLogprob,
                noSpeechProb: segment.noSpeechProb,
                compressionRatio: segment.compressionRatio
            )
        }
        return TranscriptionResult(
            id: fileURL.lastPathComponent,
            text: text,
            languageCode: payload.language,
            audioDuration: segments.compactMap(\.end).max(),
            confidence: nil,
            segments: segments
        )
    }

    private func commandArguments(
        recordingAt fileURL: URL,
        outputDirectory: URL,
        options: LocalTranscriptionOptions
    ) -> [String] {
        var arguments = [
            fileURL.path,
            "--model", options.model.rawValue,
            "--model_dir", modelDirectory.path,
            "--output_dir", outputDirectory.path,
            "--output_format", "json",
            "--verbose", "False",
            "--task", "transcribe",
            "--fp16", "False"
        ]
        if let language = options.language.commandLineValue {
            arguments += ["--language", language]
        }
        let prompt = VocabularyPrompt.build(options.keyterms)
        if !prompt.isEmpty {
            arguments += [
                "--initial_prompt", prompt,
                "--carry_initial_prompt", "True"
            ]
        }
        return arguments
    }

    /// Runs the CLI, streaming its merged stdout+stderr so `tqdm` progress bars can be parsed live,
    /// while still accumulating the full output for error diagnostics. Both streams share one pipe
    /// to avoid the classic two-pipe fill-buffer deadlock.
    private func run(
        arguments: [String],
        workingDirectory: URL,
        onProgress: @escaping ProgressHandler
    ) async throws -> String {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        var environment = ProcessInfo.processInfo.environment
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
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

            var parser = WhisperProgressParser()
            var logData = Data()
            for await data in dataStream {
                logData.append(data)
                if logData.count > 200_000 {
                    logData = logData.suffix(100_000)
                }
                if let progress = parser.consume(String(decoding: data, as: UTF8.self)) {
                    await onProgress(progress)
                }
            }
            // The pipe reached EOF, so the process has closed its handles; make sure it has fully
            // exited before reading its termination status — via terminationHandler, not the blocking
            // waitUntilExit() (see armedExitStream).
            for await _ in processExited {}
            handle.readabilityHandler = nil

            let log = String(decoding: logData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try Task.checkCancellation()
            let status = process.terminationStatus
            guard status == 0 else {
                let diagnostic = String(log.suffix(4_000))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw LocalWhisperError.processFailed(
                    diagnostic.isEmpty ? "Whisper exited with status \(status)." : diagnostic
                )
            }
            return log
        } onCancel: {
            cancellation.cancel()
        }
    }
}

/// Makes process launch and cancellation one atomic decision. Without this handshake, cancellation
/// can land after a task's cancellation check but before `Process.run()`: the cancellation handler
/// sees a process that is not running yet, then the operation launches it anyway.
final class ProcessCancellationController: @unchecked Sendable {
    private let process: Process
    private let willRun: () -> Void
    private let lock = NSLock()
    private var cancellationRequested = false

    init(process: Process, willRun: @escaping () -> Void = {}) {
        self.process = process
        self.willRun = willRun
    }

    func runUnlessCancelled() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancellationRequested,
              !Task<Never, Never>.isCancelled else {
            throw CancellationError()
        }
        willRun()
        try process.run()
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        if process.isRunning {
            process.terminate()
        }
        lock.unlock()
    }
}

/// Arms `process.terminationHandler` — call this BEFORE `process.run()` — and returns a stream that
/// finishes when the child exits. After draining the process's output, `for await _ in stream {}` to
/// wait for exit before reading `terminationStatus`. This replaces the blocking `Process.waitUntilExit()`,
/// which spins a CFRunLoop on the *calling* thread; on a Swift-concurrency cooperative worker the child's
/// termination wake-up is delivered to a different run loop and the wait can wedge forever under suite
/// load — the F115/F121 hang the suite runs `--no-parallel` to dodge, which F165's extra subprocess tests
/// tipped into a deterministic stall. A termination that lands before the await is buffered by the
/// stream, so no exit is ever missed.
func armedExitStream(for process: Process) -> AsyncStream<Void> {
    AsyncStream { continuation in
        process.terminationHandler = { _ in continuation.finish() }
    }
}

private struct WhisperOutput: Decodable {
    let text: String
    let language: String?
    let segments: [WhisperSegment]
}

private struct WhisperSegment: Decodable {
    let start: Double?
    let end: Double?
    let text: String
    let avgLogprob: Double?
    let noSpeechProb: Double?
    let compressionRatio: Double?

    enum CodingKeys: String, CodingKey {
        case start, end, text
        case avgLogprob = "avg_logprob"
        case noSpeechProb = "no_speech_prob"
        case compressionRatio = "compression_ratio"
    }
}
