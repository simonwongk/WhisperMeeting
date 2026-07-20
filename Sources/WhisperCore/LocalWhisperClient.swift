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
                text: segmentText
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
        let prompt = vocabularyPrompt(options.keyterms)
        if !prompt.isEmpty {
            arguments += [
                "--initial_prompt", prompt,
                "--carry_initial_prompt", "True"
            ]
        }
        return arguments
    }

    private func vocabularyPrompt(_ keyterms: [String]) -> String {
        let prompt = keyterms
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(100)
            .joined(separator: ", ")
        return String(prompt.prefix(1_000))
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

        let handle = pipe.fileHandleForReading
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
            try Task.checkCancellation()
            try process.run()

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
            // If cancellation landed in the tiny window between the checkCancellation above and
            // process.run() marking the process running, onCancel's isRunning guard may have
            // skipped terminate(). Terminate here so waitUntilExit() cannot stall on a live child.
            if Task.isCancelled, process.isRunning {
                process.terminate()
            }
            // The pipe reached EOF, so the process has closed its handles; make sure it has fully
            // exited before reading its termination status.
            process.waitUntilExit()
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
            if process.isRunning { process.terminate() }
        }
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
}
