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
    /// `applicationSupport` is the injected seam tests and installers use and wins outright; the
    /// process-wide `WHISPERMEET_LIBRARY` override applies only when nothing narrower was given
    /// (F312).
    public static func managedDirectory(
        applicationSupport: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        libraryRoot(applicationSupport: applicationSupport, environment: environment)
            .appendingPathComponent("Runtime", isDirectory: true)
    }

    public static func managedExecutable(applicationSupport: URL? = nil) -> URL {
        managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("venv/bin/whisper")
    }

    public static func modelDirectory(
        applicationSupport: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        libraryRoot(applicationSupport: applicationSupport, environment: environment)
            .appendingPathComponent("Models", isDirectory: true)
    }

    private static func libraryRoot(applicationSupport: URL?, environment: [String: String]) -> URL {
        if let applicationSupport {
            return applicationSupport.appendingPathComponent("WhisperMeet", isDirectory: true)
        }
        return WhisperMeetLibrary.root(environment: environment)
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

    /// Whether `executableURL` accepts `--carry_initial_prompt`, which openai-whisper shipped in
    /// 20250625 (F509). `findExecutable()` accepts ANY `whisper` on `/opt/homebrew/bin`,
    /// `/usr/local/bin` or `~/.local/bin` with no version check, and `LocalWhisperClient
    /// .commandArguments` unconditionally adds that flag the moment the meeting has any vocabulary
    /// term — so an older Homebrew or pipx install exits 2 on argparse for every such meeting, and
    /// the failure classifies as "retry", which can never succeed.
    ///
    /// Probed with `--help` rather than a version string: openai-whisper's CLI has no `--version`.
    ///
    /// **This is not cheap — measure before calling it on the main actor.** An earlier version of
    /// this comment said a `--help` run "costs a few tens of milliseconds," which was a guess and
    /// was wrong by an order of magnitude: `--help` still starts a full Python interpreter and
    /// imports `whisper.transcribe`, which transitively imports torch. Measured directly against
    /// the installed `openai-whisper==20250625` in a throwaway venv (`/usr/bin/time -p whisper
    /// --help >/dev/null`, warm runs after the first cold one): **~1.0–1.1 s wall-clock**, not tens
    /// of milliseconds — consistent with an independent reviewer's measurement of the app's own
    /// installed executable at 0.859 s. `AppModel` therefore never calls this synchronously on the
    /// main actor: it memoizes the result per executable and runs the first probe off-actor (see
    /// `AppModel.updateVocabularyPromptSupport`).
    ///
    /// Returns `false` — never throws — for a missing, non-executable, or unresponsive binary, so a
    /// caller can use it as a plain capability gate.
    public static func supportsCarryInitialPrompt(at executableURL: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { return false }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--help"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe() // drained so a chatty --help can never fill the pipe and hang
        do {
            try process.run()
        } catch {
            return false
        }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }
        return String(decoding: data, as: UTF8.self).contains("--carry_initial_prompt")
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

    /// The file openai-whisper's CLI keeps `model` in under `--model_dir` (F823). `_download` saves
    /// a checkpoint as the basename of its `_MODELS` URL — `os.path.join(root, os.path.basename(url))`
    /// — and the CLI passes `--model_dir` as that root. `_MODELS` maps "turbo" to
    /// `…/large-v3-turbo.pt` and "large" to `…/large-v3.pt`: checked in the pinned
    /// openai-whisper 20250625 (`whisper/__init__.py:29-31`, `:58` as installed by
    /// `setup-local-whisper.sh`) and on github.com/openai/whisper main, 2026-10-07.
    public static func checkpointFileName(for model: WhisperModel) -> String {
        switch model {
        case .large: "large-v3.pt"
        case .turbo: "large-v3-turbo.pt"
        }
    }

    /// Whether the openai-whisper checkpoint for `model` is in the app's model directory — the
    /// model the batch dictation engine runs where the warm MLX helper cannot (F823). Presence, as
    /// `mlxModelCached` checks presence: whisper itself re-verifies the checksum when it loads.
    public static func checkpointCached(_ model: WhisperModel, applicationSupport: URL? = nil) -> Bool {
        FileManager.default.fileExists(
            atPath: modelDirectory(applicationSupport: applicationSupport)
                .appendingPathComponent(checkpointFileName(for: model)).path
        )
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
    /// Where a long recording is cut (F533). Internal so a test can see what the app builds.
    let piecePolicy: WhisperPiecePolicy
    /// The `ffmpeg` that decodes a recording to measure and cut it; nil finds the one Whisper itself
    /// would run, on the same `PATH` (`subprocessPATH`).
    private let ffmpegExecutableURL: URL?
    /// Where each run's working folder goes; nil is the system temporary directory.
    private let scratchDirectory: URL?

    /// `piecePolicy`, `ffmpegExecutableURL` and `scratchDirectory` exist for tests (F533); the app
    /// passes none of them.
    public init(
        executableURL: URL,
        modelDirectory: URL,
        piecePolicy: WhisperPiecePolicy = .standard,
        ffmpegExecutableURL: URL? = nil,
        scratchDirectory: URL? = nil
    ) {
        self.executableURL = executableURL
        self.modelDirectory = modelDirectory
        self.piecePolicy = piecePolicy
        self.ffmpegExecutableURL = ffmpegExecutableURL
        self.scratchDirectory = scratchDirectory
    }

    /// Transcribes a recording in its original language.
    ///
    /// **A recording longer than `piecePolicy.maximumPieceSeconds` is transcribed in pieces (F533).**
    /// It is decoded once — with openai-whisper's own `load_audio` command, so every piece holds the
    /// exact samples one pass would have seen — measured, cut at quiet moments, and each piece is
    /// written to the run's working folder and given to its own `whisper` process, so no process
    /// ever builds the spectrogram of more than one piece. Language detection runs on the first
    /// piece only, which starts where the recording does, and its answer is pinned for the rest —
    /// one pass also detects once, from the first 30 seconds. Times are offset back onto the
    /// recording's clock and the pieces are joined (`WhisperPieceJoin`). Any piece failing fails
    /// the whole run; nothing partial is returned. The recording itself is only ever read.
    ///
    /// A recording within the bound is one call on the original file, exactly as before.
    public func transcribe(
        recordingAt fileURL: URL,
        options: LocalTranscriptionOptions = .accuracyFirst(),
        onProgress: ProgressHandler? = nil
    ) async throws -> TranscriptionResult {
        // F718: the no-op is written here, not as the default argument, so it is compiled once in
        // this module. A closure in a public default argument is copied into every client module.
        let onProgress: ProgressHandler = onProgress ?? { _ in }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw LocalWhisperError.runtimeNotInstalled
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw LocalWhisperError.recordingNotFound
        }
        try Task.checkCancellation()

        let workingDirectory = (scratchDirectory ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("WhisperMeet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )
        // Removes the decoded audio and every piece with it, however the run ends.
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        await onProgress(.preparing)
        guard let decoded = try await decodeForPieces(fileURL, in: workingDirectory) else {
            // Whisper loads (and on first use downloads) the model before it transcribes; the parser
            // upgrades the phase as soon as the CLI starts reporting a progress bar.
            await onProgress(.loadingModel)
            let transcript = try await transcribePiece(
                fileURL, outputDirectory: workingDirectory, options: options, pinnedLanguage: nil,
                onProgress: onProgress
            )
            return try WhisperPieceJoin.join([(0, transcript)], id: fileURL.lastPathComponent)
        }

        let pieces = decoded.pieces
        var transcripts: [(offsetSeconds: Double, transcript: WhisperPieceTranscript)] = []
        var detectedLanguage: String?
        for (index, piece) in pieces.enumerated() {
            try Task.checkCancellation()
            let pieceURL = workingDirectory.appendingPathComponent("whispermeet-piece-\(index + 1).wav")
            try WhisperPieceAudio.writePiece(piece, from: decoded.audioURL, to: pieceURL)
            let mapped: ProgressHandler = { progress in
                await onProgress(WhisperPieceProgress.overall(progress, pieceIndex: index, pieces: pieces))
            }
            await mapped(.loadingModel)
            let transcript = try await transcribePiece(
                pieceURL, outputDirectory: workingDirectory, options: options,
                pinnedLanguage: detectedLanguage, onProgress: mapped
            )
            try? FileManager.default.removeItem(at: pieceURL)
            if index == 0, options.language.commandLineValue == nil {
                detectedLanguage = transcript.language
            }
            transcripts.append((Double(piece.lowerBound) / Double(WhisperPiecePlanner.sampleRate), transcript))
        }
        return try WhisperPieceJoin.join(transcripts, id: fileURL.lastPathComponent)
    }

    /// The recording decoded to 16 kHz mono 16-bit PCM, and where to cut it.
    private struct DecodedRecording {
        let audioURL: URL
        let pieces: [Range<Int>]
    }

    /// Decodes and plans a recording that may be longer than the bound, or returns nil when it is
    /// to be transcribed whole as before (F533):
    ///
    /// - a WAV whose header puts it within the bound — the common case, measured without a decode;
    /// - a `.wav` that `WAVInspection` — which reads every WAV the app itself writes, RIFF and
    ///   RF64 — cannot read: it is given to Whisper exactly as before, failures and all;
    /// - no `ffmpeg` on Whisper's `PATH`: Whisper cannot decode anything either and fails at
    ///   `load_audio`, before any spectrogram exists, with the error it always gave;
    /// - a decode that turns out to be within the bound after all.
    ///
    /// A decode that fails throws, before Whisper runs: the meeting stays retryable.
    private func decodeForPieces(_ fileURL: URL, in workingDirectory: URL) async throws -> DecodedRecording? {
        let wavSeconds = WhisperPieceAudio.wavDurationSeconds(at: fileURL)
        if let wavSeconds, wavSeconds <= piecePolicy.maximumPieceSeconds { return nil }
        if wavSeconds == nil, fileURL.pathExtension.lowercased() == "wav",
           WAVInspection.header(at: fileURL) == nil {
            return nil
        }
        guard let ffmpeg = ffmpegExecutableURL ?? Self.findFFmpeg(path: Self.subprocessPATH()) else { return nil }

        let audioURL = workingDirectory.appendingPathComponent("whispermeet-decoded.s16le")
        let log = try await run(
            executable: ffmpeg,
            arguments: Self.decodeArguments(input: fileURL, output: audioURL),
            onProgress: { _ in },
            failure: { status, diagnostic in
                LocalWhisperError.processFailed(
                    "the recording could not be decoded to transcribe it in pieces"
                        + (diagnostic.isEmpty ? " (ffmpeg exited with status \(status))." : ": \(diagnostic)")
                )
            }
        )
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw LocalWhisperError.processFailed(
                "the recording could not be decoded to transcribe it in pieces: "
                    + SubprocessLogSummary.summarize(log.isEmpty ? "ffmpeg wrote no audio." : log)
            )
        }
        let energy = try WhisperPieceAudio.measure(audioURL)
        let pieces = WhisperPiecePlanner.pieces(
            totalSamples: energy.sampleCount, frameEnergies: energy.frameEnergies(), policy: piecePolicy
        )
        guard pieces.count > 1 else {
            try? FileManager.default.removeItem(at: audioURL)
            return nil
        }
        return DecodedRecording(audioURL: audioURL, pieces: pieces)
    }

    /// openai-whisper's own decode, `load_audio` (`whisper/audio.py:45-55`, identical in the pinned
    /// 20250625 and on main, 2026-10-08), writing to a file instead of a pipe: the same input
    /// options, format, channel count, codec and rate, so the samples are the ones one pass would
    /// have transcribed. `-hide_banner -loglevel error` keep the log to errors and change no sample;
    /// `-y` because the path is this run's own.
    static func decodeArguments(input: URL, output: URL) -> [String] {
        [
            "-hide_banner", "-loglevel", "error",
            "-nostdin", "-threads", "0", "-i", input.path,
            "-f", "s16le", "-ac", "1", "-acodec", "pcm_s16le", "-ar", String(WhisperPiecePlanner.sampleRate),
            "-y", output.path,
        ]
    }

    /// The `PATH` every subprocess here runs with: Homebrew first, then whatever the app was given.
    /// Whisper's `load_audio` runs a bare `ffmpeg`, so this is also where it finds one.
    static func subprocessPATH(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        "/opt/homebrew/bin:/usr/local/bin:\(environment["PATH"] ?? "/usr/bin:/bin")"
    }

    /// The first executable `ffmpeg` on `path`, as a `PATH` search finds it.
    static func findFFmpeg(path: String) -> URL? {
        path.split(separator: ":").lazy
            .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("ffmpeg") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// One `whisper` run over one file, read back as a piece transcript (times relative to `audio`).
    private func transcribePiece(
        _ audio: URL,
        outputDirectory: URL,
        options: LocalTranscriptionOptions,
        pinnedLanguage: String?,
        onProgress: @escaping ProgressHandler
    ) async throws -> WhisperPieceTranscript {
        let arguments = commandArguments(
            recordingAt: audio,
            outputDirectory: outputDirectory,
            options: options,
            pinnedLanguage: pinnedLanguage
        )
        let log = try await run(
            executable: executableURL,
            arguments: arguments,
            onProgress: onProgress,
            failure: { status, diagnostic in
                LocalWhisperError.processFailed(diagnostic.isEmpty ? "Whisper exited with status \(status)." : diagnostic)
            }
        )
        try Task.checkCancellation()

        let outputURL = outputDirectory
            .appendingPathComponent(audio.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            // Whisper's normal failure mode (an ffmpeg decode error or OOM mid-file) is caught
            // inside its own cli(), printed as a traceback, and followed by exit 0 — so this
            // branch, not the non-zero-exit one in `run`, is what a real failure usually hits.
            // Summarized the same way (F511): the full accumulated log can run to ~200 KB, all of
            // which would otherwise land in the alert and in meetings.json's errorMessage.
            if !log.isEmpty { throw LocalWhisperError.processFailed(SubprocessLogSummary.summarize(log)) }
            throw LocalWhisperError.missingOutput
        }
        guard let payload = try? JSONDecoder().decode(
            WhisperOutput.self,
            from: Data(contentsOf: outputURL)
        ) else {
            throw LocalWhisperError.unreadableOutput
        }
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
        return WhisperPieceTranscript(text: payload.text, language: payload.language, segments: segments)
    }

    /// Every flag the installed `whisper` CLI accepts, as a guard on what we may pass (F264).
    ///
    /// **What this catches, and what it does not.** It catches *us* passing a flag openai-whisper has
    /// never had — most usefully a faster-whisper / HuggingFace name reached for while fixing a
    /// repetition loop. It does **not** detect upstream drift, and an earlier version of this comment
    /// claimed it did: the list is a hardcoded literal and the test checks `commandArguments` against
    /// that same literal, so nothing reads the installed CLI. If a future
    /// `pip install --upgrade openai-whisper` removes `--carry_initial_prompt`, both this list and
    /// `commandArguments` stay unchanged, the test stays green, and the meeting still dies with
    /// argparse exit 2 → `LocalWhisperError.processFailed` and no transcript.
    ///
    /// Detecting that needs the suite to shell out to the installed runtime, which the rest of
    /// WhisperCore deliberately avoids — its tests must pass with no model installed. The residual
    /// risk is real and is why the runtime being unpinned (`Scripts/setup-local-whisper.sh:109`) is
    /// worth revisiting; the mitigation here is a snapshot to re-derive against, not a tripwire.
    ///
    /// Derived from the installed runtime's own argparse setup (openai-whisper 20250625,
    /// `whisper/transcribe.py`), not from memory — the command to re-derive it is in that test file.
    /// When upstream genuinely changes, re-run it and update this list in the same commit.
    ///
    /// Deliberately absent: `--repetition_penalty`, `--no_repeat_ngram_size`, `--vad_filter`,
    /// `--condition_on_prev_tokens`, `--chunk_length`, `--batch_size`. Those are
    /// faster-whisper / HuggingFace names, and reaching for one is the mistake this list catches.
    static let supportedCLIFlags: Set<String> = [
        "--append_punctuations", "--beam_size", "--best_of", "--carry_initial_prompt",
        "--clip_timestamps", "--compression_ratio_threshold", "--condition_on_previous_text",
        "--device", "--fp16", "--hallucination_silence_threshold", "--highlight_words",
        "--initial_prompt", "--language", "--length_penalty", "--logprob_threshold",
        "--max_line_count", "--max_line_width", "--max_words_per_line", "--model", "--model_dir",
        "--no_speech_threshold", "--output_dir", "--output_format", "--patience",
        "--prepend_punctuations", "--suppress_tokens", "--task", "--temperature",
        "--temperature_increment_on_fallback", "--threads", "--verbose", "--word_timestamps"
    ]

    /// Internal rather than private so `WhisperCLIFlagAllowlistTests` can check what we actually
    /// pass (F264). It was private and entirely untested.
    ///
    /// `pinnedLanguage` is what the first piece of a long recording detected (F533), passed to the
    /// pieces after it so the recording is transcribed in one language, as a single pass would be. A
    /// language the user chose always wins. It is the JSON `language` openai-whisper wrote — a key
    /// of `LANGUAGES` — and `--language` accepts every key (`transcribe.py:538`, `choices=sorted(
    /// LANGUAGES.keys()) + …`).
    func commandArguments(
        recordingAt fileURL: URL,
        outputDirectory: URL,
        options: LocalTranscriptionOptions,
        pinnedLanguage: String? = nil
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
        if let language = options.language.commandLineValue ?? pinnedLanguage {
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

    /// Runs `executable` (the `whisper` CLI, or the `ffmpeg` decode before a split), streaming its
    /// merged stdout+stderr so `tqdm` progress bars can be parsed live, while still accumulating the
    /// full output for error diagnostics. Both streams share one pipe to avoid the classic two-pipe
    /// fill-buffer deadlock. A non-zero exit throws what `failure` makes of its status and the last
    /// 4,000 characters of output.
    private func run(
        executable: URL,
        arguments: [String],
        onProgress: @escaping ProgressHandler,
        failure: (Int32, String) -> LocalWhisperError
    ) async throws -> String {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Self.subprocessPATH(environment)
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
                throw failure(status, diagnostic)
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
