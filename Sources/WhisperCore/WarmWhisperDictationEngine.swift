// Sources/WhisperCore/WarmWhisperDictationEngine.swift
import Foundation

/// Keeps a Whisper model resident in a child Python process, driven over stdin/stdout
/// newline-delimited JSON, so repeat dictations skip the multi-second model-load cost.
/// All process/IO work is serialized on a private queue; the model is evicted on `shutdown()`.
public final class WarmWhisperDictationEngine: DictationEngine, @unchecked Sendable {
    private let python: URL
    private let script: URL
    private let modelDirectory: URL
    private let model: WhisperModel
    private let queue = DispatchQueue(label: "com.whispermeet.dictation.engine")

    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var stdoutBuffer = Data()

    public init(python: URL, script: URL, modelDirectory: URL, model: WhisperModel = .turbo) {
        self.python = python
        self.script = script
        self.modelDirectory = modelDirectory
        self.model = model
    }

    public func warmUp() async throws {
        try await run { try self.ensureRunning() }
    }

    public func transcribe(
        wavAt url: URL,
        language: WhisperLanguage,
        initialPrompt: String?
    ) async throws -> DictationResult {
        try await run {
            try self.ensureRunning()
            let request = DictationRequest(
                wavPath: url.path,
                language: language.commandLineValue,
                initialPrompt: initialPrompt
            )
            self.stdin?.write(try DictationWireProtocol.encodeLine(request))
            let line = try self.readLine(timeout: 120)
            let response = try DictationWireProtocol.decodeResponse(line: line)
            if let error = response.error {
                throw LocalWhisperError.processFailed(error)
            }
            let text = (response.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return DictationResult(text: text, languageCode: response.language)
        }
    }

    public func shutdown() {
        queue.async {
            try? self.stdin?.close()
            self.process?.terminate()
            self.process = nil
            self.stdin = nil
            self.stdout = nil
            self.stdoutBuffer.removeAll()
        }
    }

    // MARK: - Serialized helpers (always run on `queue`)

    private func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func ensureRunning() throws {
        if let process, process.isRunning { return }
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw LocalWhisperError.runtimeNotInstalled
        }
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw LocalWhisperError.runtimeNotInstalled
        }
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = python
        process.arguments = [script.path, "--model", model.rawValue, "--model-dir", modelDirectory.path]
        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        try process.run()

        self.process = process
        self.stdin = inPipe.fileHandleForWriting
        self.stdout = outPipe.fileHandleForReading
        self.stdoutBuffer.removeAll()

        // Block until the helper reports the model is resident.
        // First enable may download the turbo model (~1.6 GB); give the one-time download+load room
        // before the watchdog kills the helper. Subsequent warm-ups (model cached) return in seconds.
        let readyLine = try readLine(timeout: 1_800)
        guard
            let ready = try? JSONDecoder().decode([String: Bool].self, from: readyLine),
            ready["ready"] == true
        else {
            throw LocalWhisperError.processFailed("Dictation helper failed to start.")
        }
    }

    private func readLine(timeout: TimeInterval) throws -> Data {
        // `availableData` blocks until data or EOF. A silent-but-alive helper would otherwise hang
        // this read (and, since all work is serialized on `queue`, the whole engine) forever. An
        // off-queue watchdog terminates the process after `timeout`; termination closes stdout, so
        // the read returns EOF and we fail cleanly instead of hanging. (Same terminate-from-another-
        // thread pattern LocalWhisperClient's ProcessCancellationController already relies on.)
        let watchdogProcess = process
        let watchdog = DispatchWorkItem { watchdogProcess?.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }

        while true {
            if let line = DictationWireProtocol.takeLine(&stdoutBuffer) { return line }
            guard let stdout else {
                throw LocalWhisperError.processFailed("Dictation helper is not running.")
            }
            let chunk = stdout.availableData
            if chunk.isEmpty {
                throw LocalWhisperError.processFailed("Dictation helper stopped unexpectedly.")
            }
            stdoutBuffer.append(chunk)
        }
    }
}

/// Cold fallback: one `whisper` CLI run per clip. No warm model — used only when the helper
/// cannot start. Reuses the existing, battle-tested `LocalWhisperClient`.
public struct BatchWhisperDictationEngine: DictationEngine {
    private let client: LocalWhisperClient
    private let model: WhisperModel

    public init(client: LocalWhisperClient, model: WhisperModel = .turbo) {
        self.client = client
        self.model = model
    }

    public func warmUp() async throws {}

    public func transcribe(
        wavAt url: URL,
        language: WhisperLanguage,
        initialPrompt: String?
    ) async throws -> DictationResult {
        let options = LocalTranscriptionOptions.accuracyFirst(
            model: model,
            language: language,
            keyterms: initialPrompt.map { [$0] } ?? []
        )
        let result = try await client.transcribe(recordingAt: url, options: options)
        return DictationResult(text: result.text, languageCode: result.languageCode)
    }

    public func shutdown() {}
}
