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

        await onProgress(.loadingModel)
        let arguments = commandArguments(
            recordingAt: fileURL,
            outputDirectory: workingDirectory,
            options: options
        )
        await onProgress(.transcribing)
        let log = try await run(arguments: arguments, workingDirectory: workingDirectory)
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

    private func run(arguments: [String], workingDirectory: URL) async throws -> String {
        let logURL = workingDirectory.appendingPathComponent("whisper.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = logHandle
        process.standardError = logHandle
        var environment = ProcessInfo.processInfo.environment
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment

        let status = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Int32, Error>) in
                guard !Task<Never, Never>.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                process.terminationHandler = { completed in
                    continuation.resume(returning: completed.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try? logHandle.close()
        let log = (try? String(contentsOf: logURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try Task.checkCancellation()
        guard status == 0 else {
            let diagnostic = String(log.suffix(4_000))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw LocalWhisperError.processFailed(
                diagnostic.isEmpty ? "Whisper exited with status \(status)." : diagnostic
            )
        }
        return log
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
