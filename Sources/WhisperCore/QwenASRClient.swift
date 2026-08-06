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

        // Decode-first (F118): mlx-audio's miniaudio can't read containers like .mp4/.mov/.aiff/.caf.
        // Transcode anything it doesn't natively decode into a 16 kHz mono WAV via afconvert (no ffmpeg
        // needed) and feed the engine that; the original recording is never touched (temp file in the
        // per-run working directory). If afconvert can't decode it either (e.g. a video-only .mov),
        // surface an "unsupported file format" error the classifier maps to switch-engine guidance.
        var audioURL = fileURL
        if AudioTranscoder.needsTranscoding(fileURL) {
            let decodedURL = workingDirectory.appendingPathComponent("decoded.wav")
            do {
                try AudioTranscoder.transcodeToWAV(input: fileURL, output: decodedURL)
                audioURL = decodedURL
            } catch {
                throw QwenASRError.processFailed(error.localizedDescription)
            }
            try Task.checkCancellation()
        }

        await onProgress(.loadingModel)
        let arguments = [
            helperScriptURL.path,
            "--model", modelDirectory.path,
            "--aligner", alignerDirectory.path,
            "--audio", audioURL.path,
            "--output", outputURL.path,
            "--language", language.commandLineValue ?? "auto",
        ]
        let log = try await run(arguments: arguments, onProgress: onProgress)
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
        let segments = QwenAlignedTranscript.segments(fullText: text, alignedItems: payload.alignedItems)
        return TranscriptionResult(
            id: id,
            text: text,
            languageCode: payload.language,
            audioDuration: payload.alignedItems.map(\.end).max(),
            confidence: nil,
            segments: segments,
            alignmentWarning: Self.alignmentWarning(text: text, segments: segments, payload: payload)
        )
    }

    /// A plain-language note whenever the transcript has text but no timestamped segments, so a Qwen
    /// meeting can never silently drop every timestamp (F30). Prefers the helper's own diagnostic (a
    /// `build_chunks`/`align_chunks` failure it reports as `alignmentWarning`); otherwise, when the
    /// helper reported success but its word timings could not be reconciled with the punctuated
    /// transcript (`QwenAlignedTranscript` returned no segments), it explains the Swift-side mismatch.
    /// Returns `nil` only when alignment actually produced timestamps.
    static func alignmentWarning(
        text: String,
        segments: [TranscriptSegment],
        payload: QwenOutput
    ) -> String? {
        // The notice claims timestamps are unavailable, so it may only appear when there genuinely
        // are none: text present but no reconciled segments. Guarding here (rather than only on the
        // helper-silent branch) keeps the message truthful even if a future helper emits a warning
        // alongside usable word timings — we would never show "unavailable" over a seekable transcript.
        guard !text.isEmpty, segments.isEmpty else { return nil }
        if let helperWarning = payload.alignmentWarning {
            return "Timestamp alignment unavailable; complete text preserved. \(helperWarning)"
        }
        return "Timestamp alignment unavailable; complete text preserved. "
            + "The recognizer's word timings could not be matched to the transcript."
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

    /// Environment for the Qwen helper subprocess. Prepends Homebrew's bin dirs to PATH so
    /// mlx-audio's `shutil.which("ffmpeg"/"ffprobe")` (`audio_io.py:67,83`) resolves the ffmpeg that
    /// `setup-local-whisper.sh` installs. A GUI-launched app inherits a bare PATH without
    /// /opt/homebrew/bin, which otherwise makes imported .m4a/.aac recordings fail with "ffmpeg not
    /// found" though ffmpeg is present (F132). Mirrors LocalWhisperClient / WarmWhisperDictationEngine.
    static func makeEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        // Stream the helper's tqdm progress live rather than only at EOF (F101).
        environment["PYTHONUNBUFFERED"] = "1"
        return environment
    }

    /// Runs the helper, streaming its stderr so per-chunk `tqdm` progress reaches `onProgress` live and
    /// no cooperative thread blocks on a full read (the streaming pattern from `LocalWhisperClient.run`;
    /// replacing the old `readDataToEndOfFile` also removes the blocking wait behind the F121 hang).
    private func run(
        arguments: [String],
        onProgress: @escaping ProgressHandler = { _ in }
    ) async throws -> String {
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

            var parser = QwenProgressParser()
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
            // Wait for the child to exit via terminationHandler, not the blocking waitUntilExit()
            // (which wedges a Swift cooperative thread under load — see armedExitStream).
            for await _ in processExited {}
            handle.readabilityHandler = nil

            let log = String(decoding: logData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try Task.checkCancellation()
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
