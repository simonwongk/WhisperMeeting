import Foundation

public enum QwenASRError: LocalizedError, Sendable, Equatable {
    case runtimeNotInstalled
    case recordingNotFound
    case processFailed(String)
    case missingOutput
    case unreadableOutput
    case emptyTranscript

    public var errorDescription: String? {
        switch self {
        case .runtimeNotInstalled:
            return "Qwen3-ASR is not installed. Open Settings and choose Install Qwen3-ASR."
        case .recordingNotFound:
            return "The meeting recording could not be found."
        case let .processFailed(message):
            return "Qwen3-ASR transcription failed: \(message)"
        case .missingOutput:
            return "Qwen3-ASR finished without creating a transcript."
        case .unreadableOutput:
            return "Qwen3-ASR created a transcript that the app could not read."
        case .emptyTranscript:
            return "No speech was detected in the recording."
        }
    }
}

public struct QwenASRRuntime: Sendable {
    public static func managedDirectory(applicationSupport: URL? = nil) -> URL {
        LocalWhisperRuntime.managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("Qwen3ASR", isDirectory: true)
    }

    public static func pythonExecutable(applicationSupport: URL? = nil) -> URL {
        managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("venv/bin/python")
    }

    public static func helperScript(applicationSupport: URL? = nil) -> URL {
        managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("qwen_transcribe.py")
    }

    public static func dictationHelperScript(applicationSupport: URL? = nil) -> URL {
        managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("qwen_dictate_server.py")
    }

    public static func modelDirectory(applicationSupport: URL? = nil) -> URL {
        managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("model", isDirectory: true)
    }

    public static func alignerDirectory(applicationSupport: URL? = nil) -> URL {
        managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("aligner", isDirectory: true)
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
            && files.fileExists(atPath: alignerDirectory(
                applicationSupport: applicationSupport
            ).appendingPathComponent("model.safetensors").path)
    }
}

public struct QwenASRClient: Sendable {
    public typealias ProgressHandler = @Sendable (LocalTranscriptionProgress) async -> Void

    private let pythonExecutableURL: URL
    private let helperScriptURL: URL
    private let modelDirectory: URL
    private let alignerDirectory: URL

    public init(
        pythonExecutableURL: URL,
        helperScriptURL: URL,
        modelDirectory: URL,
        alignerDirectory: URL
    ) {
        self.pythonExecutableURL = pythonExecutableURL
        self.helperScriptURL = helperScriptURL
        self.modelDirectory = modelDirectory
        self.alignerDirectory = alignerDirectory
    }

    public func transcribe(
        recordingAt fileURL: URL,
        language: WhisperLanguage = .automatic,
        onProgress: @escaping ProgressHandler = { _ in }
    ) async throws -> TranscriptionResult {
        guard runtimeIsComplete else { throw QwenASRError.runtimeNotInstalled }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw QwenASRError.recordingNotFound
        }
        try Task.checkCancellation()

        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperMeet-Qwen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workingDirectory) }
        let outputURL = workingDirectory.appendingPathComponent("transcript.json")

        await onProgress(.preparing)
        await onProgress(.loadingModel)
        let arguments = [
            helperScriptURL.path,
            "--model", modelDirectory.path,
            "--aligner", alignerDirectory.path,
            "--audio", fileURL.path,
            "--output", outputURL.path,
            "--language", language.commandLineValue ?? "auto",
        ]
        let log = try await run(arguments: arguments)
        try Task.checkCancellation()

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            if !log.isEmpty { throw QwenASRError.processFailed(log) }
            throw QwenASRError.missingOutput
        }
        guard let payload = try? JSONDecoder().decode(
            QwenOutput.self,
            from: Data(contentsOf: outputURL)
        ) else {
            throw QwenASRError.unreadableOutput
        }
        let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw QwenASRError.emptyTranscript }
        return Self.makeResult(id: fileURL.lastPathComponent, text: text, payload: payload)
    }

    /// Builds the result from the decoded helper payload, surfacing the alignment warning through the
    /// result rather than logging it as an OSLog side effect — keeping WhisperCore framework-free and
    /// making the warning observable to callers and tests (F28).
    static func makeResult(id: String, text: String, payload: QwenOutput) -> TranscriptionResult {
        TranscriptionResult(
            id: id,
            text: text,
            languageCode: payload.language,
            audioDuration: payload.alignedItems.map(\.end).max(),
            confidence: nil,
            segments: QwenAlignedTranscript.segments(fullText: text, alignedItems: payload.alignedItems),
            alignmentWarning: payload.alignmentWarning.flatMap {
                "Timestamp alignment unavailable; complete text preserved. \($0)"
            }
        )
    }

    private var runtimeIsComplete: Bool {
        let files = FileManager.default
        return files.isExecutableFile(atPath: pythonExecutableURL.path)
            && files.fileExists(atPath: helperScriptURL.path)
            && files.fileExists(
                atPath: modelDirectory.appendingPathComponent("model.safetensors").path
            )
            && files.fileExists(
                atPath: alignerDirectory.appendingPathComponent("model.safetensors").path
            )
    }

    private func run(arguments: [String]) async throws -> String {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = pythonExecutableURL
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        process.environment = environment
        let cancellation = ProcessCancellationController(process: process)
        let handle = pipe.fileHandleForReading

        return try await withTaskCancellationHandler {
            try cancellation.runUnlessCancelled()
            let data = handle.readDataToEndOfFile()
            process.waitUntilExit()
            try Task.checkCancellation()
            let log = String(decoding: data.suffix(100_000), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                throw QwenASRError.processFailed(
                    log.isEmpty
                        ? "Qwen helper exited with status \(process.terminationStatus)."
                        : String(log.suffix(4_000))
                )
            }
            return log
        } onCancel: {
            cancellation.cancel()
        }
    }
}

struct QwenOutput: Decodable {
    let text: String
    let language: String?
    let alignedItems: [QwenAlignedItem]
    let alignmentWarning: String?
}
