// Sources/WhisperCore/WarmWhisperDictationEngine.swift
import Darwin
import Foundation

/// Keeps a Whisper model resident in a child Python process, driven over stdin/stdout
/// newline-delimited JSON, so repeat dictations skip the multi-second model-load cost.
/// All process/IO work is serialized on a private queue; the model is evicted on `shutdown()`.
public final class WarmWhisperDictationEngine: DictationEngine, @unchecked Sendable {
    fileprivate enum Runtime {
        case whisper
        case qwen
    }

    private let python: URL
    private let script: URL
    private let launchArguments: [String]
    private let directoryToCreate: URL?
    private let runtime: Runtime
    private let queue = DispatchQueue(label: "com.whispermeet.dictation.engine")

    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var stdoutBuffer = Data()

    // Live handles for the running child, guarded by their own lock so `shutdown()` can terminate
    // it from ANY thread without waiting for the serial queue (which may be parked in a blocking
    // read). Written when the process starts, cleared when it's torn down.
    private let liveLock = NSLock()
    private var liveProcess: Process?
    private var liveStdin: FileHandle?
    private var retired = false

    // Continuously-drained stderr, so an early failure (e.g. an MLX import traceback) shows WHY the
    // helper died instead of a generic "stopped unexpectedly". Draining on a background handler
    // means stderr can never fill its pipe and deadlock the child, whatever the volume.
    private let stderrLock = NSLock()
    private var stderrText = ""
    private var stderrHandle: FileHandle?

    public init(
        python: URL,
        script: URL,
        modelDirectory: URL,
        mlxRepo: String = "mlx-community/whisper-large-v3-turbo"
    ) {
        self.python = python
        self.script = script
        self.launchArguments = [
            "--mlx-repo", mlxRepo,
            "--model-dir", modelDirectory.path,
        ]
        self.directoryToCreate = modelDirectory
        self.runtime = .whisper
    }

    fileprivate init(
        python: URL,
        script: URL,
        launchArguments: [String],
        directoryToCreate: URL?,
        runtime: Runtime
    ) {
        self.python = python
        self.script = script
        self.launchArguments = launchArguments
        self.directoryToCreate = directoryToCreate
        self.runtime = runtime
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
            if let stdin = self.stdin {
                try ThrowingFileHandleIO.write(
                    try DictationWireProtocol.encodeLine(request),
                    to: stdin
                )
            }
            let line = try self.readLine(timeout: 120)
            let response = try DictationWireProtocol.decodeResponse(line: line)
            if let error = response.error {
                throw self.processFailure(error)
            }
            let text = (response.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return DictationResult(
                text: text,
                languageCode: response.language,
                noSpeechProb: response.noSpeechProb
            )
        }
    }

    public func shutdown() {
        // Interrupt in-flight work IMMEDIATELY and off the serial queue. Terminating the child
        // closes its stdout, which unblocks any `readLine` currently parked in `availableData` so
        // the queued operation returns at once — instead of the state-cleanup below (queued behind
        // it) having to wait out the read's 120s/1800s timeout. Mirrors the off-queue terminate the
        // readLine watchdog and LocalWhisperClient's ProcessCancellationController already rely on.
        let (process, input) = captureLiveProcess()
        try? input?.close()
        process?.terminate()

        queue.async {
            self.clearProcessState()
        }
    }

    public func evict() async {
        // Meeting transcription needs the unified memory now, but this engine remains usable for
        // the next hotkey press. Close/terminate off the queue so a blocked line read unblocks,
        // then wait until cleanup confirms the child is gone before another model starts.
        let (process, input) = captureLiveProcess()
        try? input?.close()
        process?.terminate()

        await withCheckedContinuation { continuation in
            queue.async {
                self.clearProcessState()
                continuation.resume()
            }
        }
    }

    public func retire() async {
        let (process, input) = markRetiredAndCaptureLiveProcess()
        try? input?.close()
        process?.terminate()

        await withCheckedContinuation { continuation in
            queue.async {
                self.clearProcessState()
                continuation.resume()
            }
        }
    }

    private func markRetiredAndCaptureLiveProcess() -> (Process?, FileHandle?) {
        liveLock.lock()
        retired = true
        let process = liveProcess
        let input = liveStdin
        liveLock.unlock()
        return (process, input)
    }

    private func captureLiveProcess() -> (Process?, FileHandle?) {
        liveLock.lock()
        defer { liveLock.unlock() }
        return (liveProcess, liveStdin)
    }

    private func appendStderr(_ text: String) {
        stderrLock.lock(); stderrText += text; stderrLock.unlock()
    }

    private func resetStderr() {
        stderrLock.lock(); stderrText = ""; stderrLock.unlock()
    }

    /// The helper's captured stderr as a message suffix, or "" if it wrote nothing. Trailing bytes
    /// (last ~2000 chars) so a long traceback stays readable without flooding the error.
    private func stderrSuffix() -> String {
        stderrLock.lock()
        let text = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        stderrLock.unlock()
        return text.isEmpty ? "" : "\n\(text.suffix(2_000))"
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
        guard !isRetired else {
            throw processFailure("Dictation model was replaced before it finished starting.")
        }
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw runtimeMissing
        }
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw runtimeMissing
        }
        if let directoryToCreate {
            try FileManager.default.createDirectory(
                at: directoryToCreate,
                withIntermediateDirectories: true
            )
        }

        let process = Process()
        process.executableURL = python
        process.arguments = [script.path] + launchArguments
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        var environment = ProcessInfo.processInfo.environment
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
        environment["PYTHONUNBUFFERED"] = "1"
        environment["HF_HUB_DISABLE_PROGRESS_BARS"] = "1" // keep the model download off stderr
        if runtime == .qwen {
            // Qwen is installed as a pinned local snapshot. Never let dictation reach the network or
            // silently replace the verified model while a user is trying to dictate.
            environment["HF_HUB_OFFLINE"] = "1"
            environment["TRANSFORMERS_OFFLINE"] = "1"
        }
        process.environment = environment
        resetStderr()
        try process.run()

        self.process = process
        self.stdin = inPipe.fileHandleForWriting
        self.stdout = outPipe.fileHandleForReading
        self.stdoutBuffer.removeAll()
        // Drain stderr continuously into a buffer so failures carry the helper's own diagnostics.
        let errHandle = errPipe.fileHandleForReading
        self.stderrHandle = errHandle
        errHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else if let text = String(data: data, encoding: .utf8) {
                self?.appendStderr(text)
            }
        }
        // Expose the live handles so shutdown() can terminate this child off-queue.
        liveLock.lock()
        liveProcess = process
        liveStdin = self.stdin
        let shouldStop = retired
        liveLock.unlock()
        if shouldStop {
            try? self.stdin?.close()
            process.terminate()
            throw processFailure("Dictation model was replaced before it finished starting.")
        }

        // Block until the helper reports the model is resident.
        // First enable may download the model (~1.6 GB); give the one-time download+load room
        // before the watchdog kills the helper. Subsequent warm-ups (model cached) return in seconds.
        let readyLine = try readLine(timeout: 1_800)
        if let ready = try? JSONDecoder().decode([String: Bool].self, from: readyLine),
           ready["ready"] == true {
            return
        }
        // Not ready: the helper emits {"error": …} on warm-up failure. Surface that specific text
        // (not a generic message) so the self-test / diagnostics show WHY it failed.
        if let response = try? DictationWireProtocol.decodeResponse(line: readyLine),
           let error = response.error {
            throw processFailure(error)
        }
        throw processFailure("Dictation helper failed to start.\(stderrSuffix())")
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
            if let line = DictationWireProtocol.takeLine(&stdoutBuffer) {
                // Skipping happens inside the watchdog's window on purpose: chatter must not buy the
                // helper extra time, so the timeout still measures the wait for a real message.
                guard Self.isProtocolMessage(line) else {
                    appendStderr("helper stdout: \(String(decoding: line, as: UTF8.self))\n")
                    continue
                }
                return line
            }
            guard let stdout else {
                throw processFailure("Dictation helper is not running.")
            }
            let chunk = stdout.availableData
            if chunk.isEmpty {
                throw processFailure("Dictation helper stopped unexpectedly.\(stderrSuffix())")
            }
            stdoutBuffer.append(chunk)
        }
    }

    /// Every message in this protocol is a JSON object, so a line that does not start with `{` is
    /// helper chatter, not a reply. Whisper's own libraries print "Detected language: …" to stdout
    /// whenever `verbose` is not None, and reading one such line as a reply would desync the stream
    /// permanently: every later response would be answered by the previous request's line.
    private static func isProtocolMessage(_ line: Data) -> Bool {
        line.first(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D }) == 0x7B // "{"
    }

    private var runtimeMissing: Error {
        switch runtime {
        case .whisper: LocalWhisperError.runtimeNotInstalled
        case .qwen: QwenASRError.runtimeNotInstalled
        }
    }

    private func processFailure(_ message: String) -> Error {
        switch runtime {
        case .whisper: LocalWhisperError.processFailed(message)
        case .qwen: QwenASRError.processFailed(message)
        }
    }

    private var isRetired: Bool {
        liveLock.lock()
        defer { liveLock.unlock() }
        return retired
    }

    private func clearProcessState() {
        try? stdin?.close()
        if let process {
            terminateAndWait(process)
        }
        process = nil
        stdin = nil
        stdout = nil
        stdoutBuffer.removeAll()
        stderrHandle?.readabilityHandler = nil
        stderrHandle = nil
        liveLock.lock()
        liveProcess = nil
        liveStdin = nil
        liveLock.unlock()
    }

    private func terminateAndWait(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        let forceStop = DispatchWorkItem {
            if process.isRunning {
                _ = Darwin.kill(pid, SIGKILL)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: forceStop)
        process.waitUntilExit()
        forceStop.cancel()
    }
}

/// Keeps the Summarizer-runtime Qwen model resident for Quick Dictation refinement (F200), driven
/// over stdin/stdout newline-delimited JSON by `refine_server.py`. Same process-host shape as
/// `WarmWhisperDictationEngine` above (serialized queue, off-queue termination, drained stderr,
/// read watchdog); deliberately a separate class so the battle-tested transcription engine is not
/// refactored under a feature change, and placed in this file so the sanctioned `import Darwin`
/// (SIGKILL escalation) stays file-scoped per the WhisperCore purity rule. No download path exists
/// here — the model is already on disk — so the ready timeout is minutes (model load), not the
/// whisper engine's 1800 s download window.
public final class WarmRefineEngine: DictationRefineEngine, @unchecked Sendable {
    private let python: URL
    private let script: URL
    private let modelDirectory: URL
    private let queue = DispatchQueue(label: "com.whispermeet.dictation.refine")

    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var stdoutBuffer = Data()

    private let liveLock = NSLock()
    private var liveProcess: Process?
    private var liveStdin: FileHandle?

    private let stderrLock = NSLock()
    private var stderrText = ""
    private var stderrHandle: FileHandle?

    private static let readyTimeout: TimeInterval = 300
    /// The caller (`DictationRefiner`) enforces the user-facing budget; this watchdog only stops a
    /// wedged child from hanging the serial queue forever.
    private static let replyTimeout: TimeInterval = 30

    /// F203: a tiny request sent once per child process at warm-up, carrying the real base system
    /// prompt (Swift stays the prompt's source of truth), so the helper's persistent prompt cache
    /// is hot before the first dictation's refine request arrives. Queue-confined state.
    private let primePrompt: String?
    private var primed = false

    public init(python: URL, script: URL, modelDirectory: URL, primePrompt: String? = nil) {
        self.python = python
        self.script = script
        self.modelDirectory = modelDirectory
        self.primePrompt = primePrompt
    }

    public func warmUp() async throws {
        try await run {
            try self.ensureRunning()
            guard let primePrompt = self.primePrompt, !self.primed else { return }
            // Attempt-once even on failure: a helper that errors on the prime would otherwise be
            // re-primed on every press. The reply MUST be consumed here — leaving it unread would
            // desync every later request on the newline-JSON wire.
            self.primed = true
            do {
                let request = RefineRequest(text: "ready", systemPrompt: primePrompt, maxTokens: 8)
                if let stdin = self.stdin {
                    try ThrowingFileHandleIO.write(
                        try DictationWireProtocol.encodeLine(request),
                        to: stdin
                    )
                }
                _ = try self.readLine(timeout: Self.replyTimeout)
            } catch {
                // Prime is an optimization; a failure must not fail warm-up itself.
            }
        }
    }

    public func refine(_ request: RefineRequest) async throws -> String {
        try await run {
            try self.ensureRunning()
            if let stdin = self.stdin {
                try ThrowingFileHandleIO.write(
                    try DictationWireProtocol.encodeLine(request),
                    to: stdin
                )
            }
            let line = try self.readLine(timeout: Self.replyTimeout)
            let response = try JSONDecoder().decode(RefineResponse.self, from: line)
            if let error = response.error {
                throw SummarizerError.helperFailed(error)
            }
            return (response.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public func shutdown() {
        // Same off-queue interrupt as WarmWhisperDictationEngine.shutdown: terminating the child
        // closes its stdout, unblocking a parked read so queued state cleanup runs immediately.
        let (process, input) = captureLiveProcess()
        try? input?.close()
        process?.terminate()
        queue.async { self.clearProcessState() }
    }

    public func evict() async {
        // Same temporary, wait-for-exit boundary as the ASR helper above. A meeting Qwen run can
        // otherwise begin while this 4B/8B model is still consuming unified memory.
        let (process, input) = captureLiveProcess()
        try? input?.close()
        process?.terminate()

        await withCheckedContinuation { continuation in
            queue.async {
                self.clearProcessState()
                continuation.resume()
            }
        }
    }

    private func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func captureLiveProcess() -> (Process?, FileHandle?) {
        liveLock.lock()
        defer { liveLock.unlock() }
        return (liveProcess, liveStdin)
    }

    private func ensureRunning() throws {
        if let process, process.isRunning { return }
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: script.path),
              FileManager.default.fileExists(
                  atPath: modelDirectory.appendingPathComponent("model.safetensors").path
              ) else {
            throw SummarizerError.modelNotInstalled
        }

        let process = Process()
        process.executableURL = python
        process.arguments = [script.path, "--model", modelDirectory.path]
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        // Pinned local snapshot; refinement must never reach the network (the summarizer's rule).
        process.environment = LocalSummarizer.makeEnvironment()
        resetStderr()
        try process.run()
        primed = false // every fresh child starts with a cold prompt cache

        self.process = process
        self.stdin = inPipe.fileHandleForWriting
        self.stdout = outPipe.fileHandleForReading
        self.stdoutBuffer.removeAll()
        let errHandle = errPipe.fileHandleForReading
        self.stderrHandle = errHandle
        errHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else if let text = String(data: data, encoding: .utf8) {
                self?.appendStderr(text)
            }
        }
        liveLock.lock()
        liveProcess = process
        liveStdin = self.stdin
        liveLock.unlock()

        let readyLine = try readLine(timeout: Self.readyTimeout)
        if let ready = try? JSONDecoder().decode([String: Bool].self, from: readyLine),
           ready["ready"] == true {
            return
        }
        if let response = try? JSONDecoder().decode(RefineResponse.self, from: readyLine),
           let error = response.error {
            throw SummarizerError.helperFailed(error)
        }
        throw SummarizerError.helperFailed("Refine helper failed to start.\(stderrSuffix())")
    }

    private func readLine(timeout: TimeInterval) throws -> Data {
        let watchdogProcess = process
        let watchdog = DispatchWorkItem { watchdogProcess?.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }

        while true {
            if let line = DictationWireProtocol.takeLine(&stdoutBuffer) {
                guard Self.isProtocolMessage(line) else {
                    appendStderr("helper stdout: \(String(decoding: line, as: UTF8.self))\n")
                    continue
                }
                return line
            }
            guard let stdout else {
                throw SummarizerError.helperFailed("Refine helper is not running.")
            }
            let chunk = stdout.availableData
            if chunk.isEmpty {
                throw SummarizerError.helperFailed(
                    "Refine helper stopped unexpectedly.\(stderrSuffix())")
            }
            stdoutBuffer.append(chunk)
        }
    }

    private static func isProtocolMessage(_ line: Data) -> Bool {
        line.first(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D }) == 0x7B // "{"
    }

    private func appendStderr(_ text: String) {
        stderrLock.lock(); stderrText += text; stderrLock.unlock()
    }

    private func resetStderr() {
        stderrLock.lock(); stderrText = ""; stderrLock.unlock()
    }

    private func stderrSuffix() -> String {
        stderrLock.lock()
        let text = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        stderrLock.unlock()
        return text.isEmpty ? "" : "\n\(text.suffix(2_000))"
    }

    private func clearProcessState() {
        try? stdin?.close()
        if let process, process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            let forceStop = DispatchWorkItem {
                if process.isRunning { _ = Darwin.kill(pid, SIGKILL) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: forceStop)
            process.waitUntilExit()
            forceStop.cancel()
        }
        process = nil
        stdin = nil
        stdout = nil
        stdoutBuffer.removeAll()
        primed = false // a fresh child has a cold prompt cache — prime again on next warm-up
        stderrHandle?.readabilityHandler = nil
        stderrHandle = nil
        liveLock.lock()
        liveProcess = nil
        liveStdin = nil
        liveLock.unlock()
    }
}

/// Qwen adapter for the same resident-process dictation protocol. It deliberately excludes the
/// forced aligner used by meetings: dictation needs text, not timestamps, and loading the extra
/// model would increase latency and memory without improving the delivered text.
public final class WarmQwenDictationEngine: DictationEngine, @unchecked Sendable {
    private let runner: WarmWhisperDictationEngine

    public init(python: URL, script: URL, modelDirectory: URL) {
        runner = WarmWhisperDictationEngine(
            python: python,
            script: script,
            launchArguments: ["--model", modelDirectory.path],
            directoryToCreate: nil,
            runtime: .qwen
        )
    }

    public func warmUp() async throws {
        try await runner.warmUp()
    }

    public func transcribe(
        wavAt url: URL,
        language: WhisperLanguage,
        initialPrompt: String?
    ) async throws -> DictationResult {
        try await runner.transcribe(
            wavAt: url,
            language: language,
            initialPrompt: nil
        )
    }

    public func shutdown() {
        runner.shutdown()
    }

    public func evict() async {
        await runner.evict()
    }

    public func retire() async {
        await runner.retire()
    }
}

/// Prefers a primary dictation engine (the warm MLX helper) and falls back to a secondary (the
/// batch `openai/whisper` CLI) when the primary can't run on this machine — an Intel Mac, a runtime
/// without MLX, or a broken MLX install. The choice is made at warm-up: if the primary's `warmUp()`
/// throws, the fallback is used for the rest of the session. Without this, those machines lose Quick
/// Dictation entirely even though a working (slower) engine is available.
public final class FallbackDictationEngine: DictationEngine, @unchecked Sendable {
    private let primary: DictationEngine
    private let fallback: DictationEngine
    private let lock = NSLock()
    private var chosen: DictationEngine?

    public init(primary: DictationEngine, fallback: DictationEngine) {
        self.primary = primary
        self.fallback = fallback
    }

    public func warmUp() async throws {
        do {
            try await primary.warmUp()
            setChosen(primary)
        } catch {
            try await fallback.warmUp()
            setChosen(fallback)
        }
    }

    public func transcribe(
        wavAt url: URL,
        language: WhisperLanguage,
        initialPrompt: String?
    ) async throws -> DictationResult {
        if currentChoice == nil { try await warmUp() }
        let engine = currentChoice ?? fallback
        return try await engine.transcribe(wavAt: url, language: language, initialPrompt: initialPrompt)
    }

    public func shutdown() {
        primary.shutdown()
        fallback.shutdown()
    }

    public func evict() async {
        await primary.evict()
        await fallback.evict()
    }

    public func retire() async {
        await primary.retire()
        await fallback.retire()
    }

    private func setChosen(_ engine: DictationEngine) {
        lock.lock(); chosen = engine; lock.unlock()
    }

    private var currentChoice: DictationEngine? {
        lock.lock(); defer { lock.unlock() }; return chosen
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
        return DictationResult(
            text: result.text,
            languageCode: result.languageCode,
            noSpeechProb: result.segments.compactMap(\.noSpeechProb).min()
        )
    }

    public func shutdown() {}
}
