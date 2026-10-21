// Sources/WhisperCore/WarmWhisperDictationEngine.swift
import Darwin
import Foundation

/// Requests a helper exit from outside its serialized IO queue. A `FileHandle.availableData` read
/// can be parked on that queue forever when a helper ignores SIGTERM, so the SIGKILL escalation
/// must be armed here rather than only in queued cleanup. The work item captures this exact
/// `Process` and PID; it can never kill a later re-warmed helper.
private func requestHelperTermination(
    process: Process?,
    input: FileHandle?
) {
    try? input?.close()
    guard let process, process.isRunning else { return }

    let pid = process.processIdentifier
    let forceStop = DispatchWorkItem { [weak process] in
        guard let process, process.isRunning else { return }
        // Signal the whole process group, not just the helper. The helper spawns its own children
        // — mlx_whisper shells out to `ffmpeg` to decode every clip — and a pid-only SIGKILL both
        // orphans whichever one is running and, for any child that inherited the helper's stdout,
        // leaves that pipe's write end open, parking our `availableData` read forever: the exact
        // hang this escalation exists to break. Foundation makes every child it spawns the leader
        // of a fresh group on Darwin; the leadership check keeps a group signal from ever reaching
        // the app's own group if that stops being true. `isRunning` means Foundation has not reaped
        // the child yet, so this pid cannot have been recycled onto an unrelated process.
        if Darwin.getpgid(pid) == pid {
            _ = Darwin.killpg(pid, SIGKILL)
        } else {
            _ = Darwin.kill(pid, SIGKILL)
        }
    }
    // An orderly exit needs no delayed work. The weak work-item capture avoids a retention cycle
    // through Process.terminationHandler, and its `isRunning` check makes repeated termination
    // requests safe even if a later request replaces this cancellation handler.
    process.terminationHandler = { _ in forceStop.cancel() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: forceStop)
    process.terminate()
}

/// An off-queue deadline for a parked read that can be pushed back (F522). Each `arm` replaces the
/// pending expiry with a new one; if one is ever allowed to run out it calls `onExpire` once from a
/// global queue. `expiredStallWindow` says afterwards whether that expiry ended a stall window, so
/// the reader can name the cause when the terminated child's stdout reads as EOF.
private final class ReadWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: DispatchWorkItem?
    private var cancelled = false
    private var expiredWindow: TimeInterval?
    private let onExpire: @Sendable () -> Void

    init(onExpire: @escaping @Sendable () -> Void) {
        self.onExpire = onExpire
    }

    func arm(after seconds: TimeInterval, inStallWindow: Bool) {
        let item = DispatchWorkItem { [weak self] in
            self?.fire(stallWindow: inStallWindow ? seconds : nil)
        }
        lock.lock()
        pending?.cancel()
        let stopped = cancelled
        pending = stopped ? nil : item
        lock.unlock()
        guard !stopped else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        pending?.cancel()
        pending = nil
        lock.unlock()
    }

    /// The stall window that expired, or nil if nothing expired or the flat budget did.
    var expiredStallWindow: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return expiredWindow
    }

    private func fire(stallWindow: TimeInterval?) {
        lock.lock()
        let stopped = cancelled
        if !stopped { expiredWindow = stallWindow }
        lock.unlock()
        guard !stopped else { return }
        onExpire()
    }
}

/// Where in a helper's start a test hook runs (F878).
enum HelperStartPoint: Sendable {
    /// The process has been launched and is not yet registered live, so a stop that lands now
    /// finds nothing to terminate.
    case launched
    /// The process is registered live; a stop that lands now terminates it.
    case registered
}

/// A helper's start was ended by `evict()` or `shutdown()` (F878).
///
/// **Not a reason to fall back.** Nothing about this Mac was learned: the helper was stopped
/// because the app asked for its memory back (a meeting is about to transcribe) or let it go
/// (dictation switched off, a cold refiner released for a press), so `FallbackDictationEngine` must
/// not read it as "the warm helper cannot run here" and move the session to the batch engine for
/// good. The next warm-up starts it again.
public struct DictationHelperStoppedError: LocalizedError, Equatable, Sendable {
    public init() {}

    public var errorDescription: String? {
        "The dictation model was stopped before it finished starting. The next dictation starts it again."
    }
}

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
    /// How many times `evict()` or `shutdown()` has asked the helper to stop (F878), guarded by
    /// `liveLock`. A start compares it with the count when its operation was asked for: a request
    /// that arrives before the new helper is registered live finds nothing to terminate, so the
    /// start itself has to see it, or the eviction waits out the whole model load.
    private var stopRequests = 0

    /// The count above, for a test.
    var stopRequestCount: Int { liveLock.withLock { stopRequests } }

    /// Run on `queue` at two points of a helper's start, for a test to land a stop exactly there
    /// (F878): right after the process is launched and before it is registered live, and right
    /// after it is registered. nil in the app.
    var helperStartHookForTesting: ((HelperStartPoint) -> Void)?

    // Continuously-drained stderr, so an early failure (e.g. an MLX import traceback) shows WHY the
    // helper died instead of a generic "stopped unexpectedly". Draining on a background handler
    // means stderr can never fill its pipe and deadlock the child, whatever the volume.
    private let stderrLock = NSLock()
    private var stderrText = ""
    private var stderrHandle: FileHandle?

    /// How long `warmUp` waits for the helper's `{"ready":true}` — model load, and on the very first
    /// run the one-time model download too. Internal so a test can shorten it.
    var warmUpTimeout: TimeInterval = 1_800
    /// Once the helper reports a download in progress (F522), the wait is no longer this flat budget
    /// but "no progress for this long". Internal so a test can shorten it.
    var downloadStallTimeout: TimeInterval = 180

    /// Told when the helper's first-run model download starts and ends (F823). Guarded by
    /// `liveLock`, because the controller sets it from the main thread while `queue` reads it.
    private var downloadObserver: DictationModelDownloadObserver?

    public func observeModelDownload(_ observer: DictationModelDownloadObserver?) {
        liveLock.lock()
        downloadObserver = observer
        liveLock.unlock()
    }

    private func reportDownload(_ downloading: Bool) {
        liveLock.lock()
        let observer = downloadObserver
        liveLock.unlock()
        observer?(downloading)
    }

    /// Told how far the download has got (F859), from the byte counts a current helper puts on its
    /// reports. Guarded by `liveLock`, like `downloadObserver`.
    private var downloadProgressObserver: DictationModelDownloadProgressObserver?

    public func observeModelDownloadProgress(_ observer: DictationModelDownloadProgressObserver?) {
        liveLock.lock()
        downloadProgressObserver = observer
        liveLock.unlock()
    }

    private func reportDownloadProgress(_ progress: DictationModelDownloadProgress) {
        liveLock.lock()
        let observer = downloadProgressObserver
        liveLock.unlock()
        observer?(progress)
    }

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
        let stops = stopRequestCount
        try await run { try self.ensureRunning(stopsWhenAsked: stops) }
    }

    /// F891: one second of silence through the resident helper's own request path (for the Qwen
    /// helper, exactly the request its startup prewarm makes) — so every weight is read once. Measured 2026-10-09: after 150 s idle
    /// the first request took 0.70 s instead of 0.32 (the user's worst case 6.9 s, from disk), the
    /// next 0.32; sent on press-down, that first request is this one, and it overlaps the speech.
    /// Nothing to do when no helper is running: `ensureRunning` is `warmUp`'s job, and a fresh helper
    /// is hot. The reply is read and discarded; an error is the caller's to ignore.
    public func touch() async throws {
        try await run {
            guard let process = self.process, process.isRunning else { return }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("dictation-touch-\(UUID().uuidString).wav")
            let silence = [Float](repeating: 0, count: 16_000)
            try WAVWriter.wavData(from: silence, sampleRate: 16_000).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let request = DictationRequest(wavPath: url.path, language: nil, initialPrompt: nil)
            if let stdin = self.stdin {
                try ThrowingFileHandleIO.write(try DictationWireProtocol.encodeLine(request), to: stdin)
            }
            _ = try self.readLine(timeout: 120)
        }
    }

    public func transcribe(
        wavAt url: URL,
        language: WhisperLanguage,
        initialPrompt: String?
    ) async throws -> DictationResult {
        let stops = stopRequestCount
        return try await run {
            try self.ensureRunning(stopsWhenAsked: stops)
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
                noSpeechProb: response.noSpeechProb,
                truncated: response.truncated ?? false
            )
        }
    }

    public func shutdown() {
        // Interrupt in-flight work IMMEDIATELY and off the serial queue. Terminating the child
        // closes its stdout, which unblocks any `readLine` currently parked in `availableData` so
        // the queued operation returns at once — instead of the state-cleanup below (queued behind
        // it) having to wait out the read's 120s/1800s timeout. Mirrors the off-queue terminate the
        // readLine watchdog and LocalWhisperClient's ProcessCancellationController already rely on.
        let (process, input) = requestStopAndCaptureLiveProcess()
        requestHelperTermination(process: process, input: input)

        queue.async {
            self.clearProcessState()
        }
    }

    public func evict() async {
        // Meeting transcription needs the unified memory now, but this engine remains usable for
        // the next hotkey press. Close/terminate off the queue so a blocked line read unblocks,
        // then wait until cleanup confirms the child is gone before another model starts.
        let (process, input) = requestStopAndCaptureLiveProcess()
        requestHelperTermination(process: process, input: input)

        await withCheckedContinuation { continuation in
            queue.async {
                self.clearProcessState()
                continuation.resume()
            }
        }
    }

    public func retire() async {
        let (process, input) = markRetiredAndCaptureLiveProcess()
        requestHelperTermination(process: process, input: input)

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

    /// Counts the stop (F878) and returns the helper to terminate, in one critical section with the
    /// start's registration, so a request is either seen by the start or finds the helper live.
    private func requestStopAndCaptureLiveProcess() -> (Process?, FileHandle?) {
        liveLock.lock()
        defer { liveLock.unlock() }
        stopRequests &+= 1
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

    /// Starts the helper unless one is running. `stopsWhenAsked` is `stopRequestCount` when the
    /// operation was asked for, before it queued (F878): an `evict()` or `shutdown()` since then was
    /// meant for this start, whether it lands before the helper is launched, before it is registered
    /// live (where it finds nothing to terminate), or after (where it terminates it mid-load). Each
    /// ends the start with `DictationHelperStoppedError` at once; the first two used to wait out the
    /// whole model load and have it killed afterwards.
    private func ensureRunning(stopsWhenAsked: Int) throws {
        if let process, process.isRunning { return }
        guard !isRetired else {
            throw processFailure("Dictation model was replaced before it finished starting.")
        }
        guard !wasAskedToStop(since: stopsWhenAsked) else { throw DictationHelperStoppedError() }
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
        helperStartHookForTesting?(.launched)
        // Expose the live handles so shutdown() can terminate this child off-queue. Read under the
        // same lock a stop counts itself under, so a stop is either seen here or finds this child.
        liveLock.lock()
        liveProcess = process
        liveStdin = self.stdin
        let shouldStop = retired
        let askedToStop = stopRequests != stopsWhenAsked
        liveLock.unlock()
        if shouldStop || askedToStop {
            // Same escalation as every other termination site: a helper that ignores TERM while
            // being retired or evicted mid-launch must not outlive this call on the strength of the
            // queued `clearProcessState()` happening to reach it later.
            requestHelperTermination(process: process, input: self.stdin)
            if shouldStop {
                throw processFailure("Dictation model was replaced before it finished starting.")
            }
            throw DictationHelperStoppedError()
        }
        helperStartHookForTesting?(.registered)

        // Block until the helper reports the model is resident. Model load gets the flat
        // `warmUpTimeout`. The first enable may also download the model (~1.6 GB), which no flat
        // budget fits — one that is long enough for a slow link is a wedged helper's wait too — so a
        // helper that reports `{"downloading":true}` as bytes arrive is instead given
        // `downloadStallTimeout` of silence, from its last report (F522). Subsequent warm-ups
        // (model cached) return in seconds and never report a download.
        let readyLine: Data
        do {
            readyLine = try readLine(timeout: warmUpTimeout, stallTimeout: downloadStallTimeout)
        } catch let download as DictationModelDownloadError {
            throw download
        } catch {
            // A stop that found this child live terminated it, and the read then ended as "stopped
            // unexpectedly". That is the stop's doing, not the helper's (F878).
            if wasAskedToStop(since: stopsWhenAsked) { throw DictationHelperStoppedError() }
            throw error
        }
        if let ready = try? JSONDecoder().decode([String: Bool].self, from: readyLine),
           ready["ready"] == true {
            return
        }
        // Not ready: the helper emits {"error": …} on warm-up failure. Surface that specific text
        // (not a generic message) so the self-test / diagnostics show WHY it failed.
        if let response = try? DictationWireProtocol.decodeResponse(line: readyLine),
           let error = response.error {
            // F827: a download that failed is a reason to retry, which the next warm-up does by
            // resuming the partial file — not a reason for `FallbackDictationEngine` to switch the
            // session to an engine that downloads a second model.
            if response.downloadFailed == true {
                throw DictationModelDownloadError(error)
            }
            throw processFailure(error)
        }
        throw processFailure("Dictation helper failed to start.\(stderrSuffix())")
    }

    /// Reads one reply line.
    ///
    /// `stallTimeout` is only for the warm-up (F522). When it is set, a `{"downloading":true}` line
    /// is consumed as a progress report and moves the deadline to `stallTimeout` from now, and a
    /// `{"downloading":false}` line moves it back to `timeout` from now; neither is returned.
    /// Everything else — chatter, and every request read, which passes no `stallTimeout` — is
    /// exactly as before: chatter and unrecognised lines never move the deadline.
    ///
    /// The download observer (F823) hears the first `true` of a run of reports and its end: the
    /// helper's `false`, or this read ending any other way — the reply, a stall, the helper dying or
    /// being stopped — so a download can never be left showing after the wait is over.
    private func readLine(timeout: TimeInterval, stallTimeout: TimeInterval? = nil) throws -> Data {
        var reportedDownloading = false
        defer { if reportedDownloading { reportDownload(false) } }
        // `availableData` blocks until data or EOF. A silent-but-alive helper would otherwise hang
        // this read (and, since all work is serialized on `queue`, the whole engine) forever. An
        // off-queue watchdog terminates the process after `timeout`; termination closes stdout, so
        // the read returns EOF and we fail cleanly instead of hanging. (Same terminate-from-another-
        // thread pattern LocalWhisperClient's ProcessCancellationController already relies on.)
        let watchdogProcess = process
        // Deliberately no stdin here. Terminating closes the helper's STDOUT, which is what unblocks
        // this read; closing our stdin buys nothing and is actively harmful, because `defer`-cancel
        // cannot stop a work item that has already begun. A reply landing exactly on the deadline
        // would leave `self.stdin` closed but non-nil with the process still `isRunning`, so
        // `ensureRunning()` would short-circuit and the next request would fail EBADF on write
        // instead of respawning.
        let watchdog = ReadWatchdog {
            requestHelperTermination(process: watchdogProcess, input: nil)
        }
        watchdog.arm(after: timeout, inStallWindow: false)
        defer { watchdog.cancel() }

        while true {
            if let line = DictationWireProtocol.takeLine(&stdoutBuffer) {
                if let stallTimeout, let report = Self.downloadReport(in: line) {
                    if report.downloading {
                        watchdog.arm(after: stallTimeout, inStallWindow: true)
                    } else {
                        watchdog.arm(after: timeout, inStallWindow: false)
                    }
                    if report.downloading != reportedDownloading {
                        reportedDownloading = report.downloading
                        reportDownload(report.downloading)
                    }
                    // After the `true` above, so the app never hears a figure for a download it has
                    // not been told about (F859). A helper that sends no counts sends no figure.
                    if report.downloading, let progress = report.progress {
                        reportDownloadProgress(progress)
                    }
                    continue
                }
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
                if let stalledFor = watchdog.expiredStallWindow {
                    // `DictationModelDownloadError`, not `processFailure`: the stall is the download's,
                    // and `FallbackDictationEngine` must be able to tell it from "cannot run here" (F827).
                    throw DictationModelDownloadError(
                        "The dictation model download made no progress for \(Int(saturating: stalledFor.rounded())) seconds and was stopped. "
                            + "Check your connection and try again; a download continues from where it stopped when it can."
                    )
                }
                throw processFailure("Dictation helper stopped unexpectedly.\(stderrSuffix())")
            }
            stdoutBuffer.append(chunk)
        }
    }

    /// A helper's `{"downloading": …}` progress line, nil for everything else. A line that also
    /// carries `ready` or `error` is a reply, so it is never mistaken for progress.
    ///
    /// `downloadedBytes`/`totalBytes` (F859) are optional: a helper from before F859 sends neither,
    /// and its reports read exactly as before, with no figure. Counts that are not whole numbers,
    /// are negative, or have a total of zero are no figure either; the line still reports a
    /// download. (An app from before F859 reads `downloading` alone and never looks at the counts.)
    static func downloadReport(in line: Data) -> (downloading: Bool, progress: DictationModelDownloadProgress?)? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              object["ready"] == nil, object["error"] == nil,
              let downloading = object["downloading"] as? Bool else { return nil }
        // `as? Int64` bridges a JSON number only when it is exactly representable, so a huge or
        // fractional count is nil here rather than a trap or a silent truncation.
        let progress = (object["downloadedBytes"] as? Int64).flatMap { downloaded in
            (object["totalBytes"] as? Int64).flatMap {
                DictationModelDownloadProgress(downloadedBytes: downloaded, totalBytes: $0)
            }
        }
        return (downloading, progress)
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

    private func wasAskedToStop(since stopsWhenAsked: Int) -> Bool {
        stopRequestCount != stopsWhenAsked
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
        requestHelperTermination(process: process, input: nil)
        process.waitUntilExit()
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
    /// As `WarmWhisperDictationEngine.stopRequests` (F878): this engine had no `retired` flag, so
    /// nothing at all stopped a start that an eviction had already been asked to end.
    private var stopRequests = 0

    /// The count above, for a test.
    var stopRequestCount: Int { liveLock.withLock { stopRequests } }

    /// As `WarmWhisperDictationEngine.helperStartHookForTesting` (F878). nil in the app.
    var helperStartHookForTesting: ((HelperStartPoint) -> Void)?

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
        let stops = stopRequestCount
        try await run {
            try self.ensureRunning(stopsWhenAsked: stops)
            self.primeIfNeeded()
        }
    }

    /// Sends the prime to a child that has not had it (F203). Queue-confined, like `primed`.
    ///
    /// Called by `warmUp()` and by `refine()` (F853): a child that died between dictations is
    /// restarted by the next `refine()`'s `ensureRunning`, and without this that dictation's own
    /// prompt was the fresh child's first request, so the anchor F630 builds was its own rather
    /// than the prime's, and a near-tie could come out differently from a primed child's for that
    /// one dictation. The prime costs the restarted dictation one tiny request on top of the model
    /// load it is already paying for.
    private func primeIfNeeded() {
        guard let primePrompt, !primed else { return }
        // Attempt-once even on failure: a helper that errors on the prime would otherwise be
        // re-primed on every press. The reply MUST be consumed here — leaving it unread would
        // desync every later request on the newline-JSON wire.
        primed = true
        do {
            let request = RefineRequest(text: "ready", systemPrompt: primePrompt, maxTokens: 8)
            if let stdin {
                try ThrowingFileHandleIO.write(
                    try DictationWireProtocol.encodeLine(request),
                    to: stdin
                )
            }
            _ = try readLine(timeout: Self.replyTimeout)
        } catch {
            // Prime is an optimization; a failure must not fail warm-up or the dictation itself.
        }
    }

    /// F891: the prime's own tiny request again, on a helper that is already running, so
    /// the 4B/8B weights come back from the compressor or disk while the user is still speaking.
    /// Measured 2026-10-09: 2.31 s for the first request after 150 s idle against 0.72 s warm — past
    /// the 1.4 s budget — the `rawTimeout` three of the user's five slow dictations carried (the other
    /// two had no resident refiner to ask). Not a warm-up: a
    /// helper that is not running is left alone.
    public func touch() async throws {
        try await run {
            guard let process = self.process, process.isRunning, let primePrompt = self.primePrompt else { return }
            let request = RefineRequest(text: "ready", systemPrompt: primePrompt, maxTokens: 1)
            if let stdin = self.stdin {
                try ThrowingFileHandleIO.write(try DictationWireProtocol.encodeLine(request), to: stdin)
            }
            _ = try self.readLine(timeout: Self.replyTimeout)
        }
    }

    public func refine(_ request: RefineRequest) async throws -> String {
        let stops = stopRequestCount
        return try await run {
            try self.ensureRunning(stopsWhenAsked: stops)
            // A child this call just restarted is primed before it serves (F853).
            self.primeIfNeeded()
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
        let (process, input) = requestStopAndCaptureLiveProcess()
        requestHelperTermination(process: process, input: input)
        queue.async {
            self.clearProcessState()
        }
    }

    public func evict() async {
        // Same temporary, wait-for-exit boundary as the ASR helper above. A meeting Qwen run can
        // otherwise begin while this 4B/8B model is still consuming unified memory.
        let (process, input) = requestStopAndCaptureLiveProcess()
        requestHelperTermination(process: process, input: input)

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

    /// As `WarmWhisperDictationEngine.requestStopAndCaptureLiveProcess` (F878).
    private func requestStopAndCaptureLiveProcess() -> (Process?, FileHandle?) {
        liveLock.lock()
        defer { liveLock.unlock() }
        stopRequests &+= 1
        return (liveProcess, liveStdin)
    }

    /// As `WarmWhisperDictationEngine.ensureRunning(stopsWhenAsked:)` (F878).
    private func ensureRunning(stopsWhenAsked: Int) throws {
        if let process, process.isRunning { return }
        guard stopRequestCount == stopsWhenAsked else { throw DictationHelperStoppedError() }
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
        helperStartHookForTesting?(.launched)
        liveLock.lock()
        liveProcess = process
        liveStdin = self.stdin
        let askedToStop = stopRequests != stopsWhenAsked
        liveLock.unlock()
        if askedToStop {
            requestHelperTermination(process: process, input: self.stdin)
            throw DictationHelperStoppedError()
        }
        helperStartHookForTesting?(.registered)

        let readyLine: Data
        do {
            readyLine = try readLine(timeout: Self.readyTimeout)
        } catch {
            if stopRequestCount != stopsWhenAsked { throw DictationHelperStoppedError() }
            throw error
        }
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
        // Deliberately no stdin here. Terminating closes the helper's STDOUT, which is what unblocks
        // this read; closing our stdin buys nothing and is actively harmful, because `defer`-cancel
        // cannot stop a work item that has already begun. A reply landing exactly on the deadline
        // would leave `self.stdin` closed but non-nil with the process still `isRunning`, so
        // `ensureRunning()` would short-circuit and the next request would fail EBADF on write
        // instead of respawning.
        let watchdog = DispatchWorkItem {
            requestHelperTermination(process: watchdogProcess, input: nil)
        }
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
            requestHelperTermination(process: process, input: nil)
            process.waitUntilExit()
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

    public func touch() async throws {
        try await runner.touch()
    }

    /// Qwen's model is a pinned local snapshot run offline, so this is never called today; it is
    /// forwarded so the shared runner's reports could not go unheard if that changed.
    public func observeModelDownload(_ observer: DictationModelDownloadObserver?) {
        runner.observeModelDownload(observer)
    }

    public func observeModelDownloadProgress(_ observer: DictationModelDownloadProgressObserver?) {
        runner.observeModelDownloadProgress(observer)
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
///
/// It is **not** for a primary whose model is still downloading (F827): `DictationModelDownloadError`
/// propagates instead. The batch engine would download a second model on the same link and cannot
/// resume it, and the choice sticks for the session; the primary's helper keeps its partial download
/// (on its resumable path), so telling the user and letting the next warm-up resume costs less and
/// keeps the fast engine. Nor for a primary whose start was ended by `evict()` or `shutdown()`
/// (`DictationHelperStoppedError`, F878): a meeting that needed the memory says nothing about this Mac.
public final class FallbackDictationEngine: DictationEngine, @unchecked Sendable {
    private let primary: DictationEngine
    private let fallback: DictationEngine
    private let lock = NSLock()
    private var chosen: DictationEngine?

    public init(primary: DictationEngine, fallback: DictationEngine) {
        self.primary = primary
        self.fallback = fallback
    }

    /// Both engines report (F823): the batch engine has nothing to say today, but the observer is
    /// not this type's to drop.
    public func observeModelDownload(_ observer: DictationModelDownloadObserver?) {
        primary.observeModelDownload(observer)
        fallback.observeModelDownload(observer)
    }

    public func observeModelDownloadProgress(_ observer: DictationModelDownloadProgressObserver?) {
        primary.observeModelDownloadProgress(observer)
        fallback.observeModelDownloadProgress(observer)
    }

    public func warmUp() async throws {
        do {
            try await primary.warmUp()
            setChosen(primary)
        } catch let download as DictationModelDownloadError {
            // Nothing is chosen, so the next `warmUp` — or the `transcribe` that triggers one — tries
            // the primary again and resumes the download.
            throw download
        } catch let stopped as DictationHelperStoppedError {
            // F878: evicted or shut down mid-start (a meeting wanted the memory). Nothing about this
            // Mac was learned, so nothing is chosen and the next warm-up tries the primary again.
            throw stopped
        } catch {
            try await fallback.warmUp()
            setChosen(fallback)
        }
    }

    /// Only a chosen engine can have something resident; before the choice there is nothing to wake.
    public func touch() async throws {
        try await currentChoice?.touch()
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
///
/// **Its model's first-use download is reported, and bounded (F860).** On a Mac without the warm
/// helper (Intel), openai-whisper downloads the turbo checkpoint (about 1.6 GB) inside the first
/// dictation's CLI run, and that was silent under "Transcribing…" with no limit: its `_download`
/// calls `urllib.request.urlopen(url)` with no timeout (`whisper/__init__.py:73` in the pinned
/// 20250625, and on github.com/openai/whisper main, 2026-10-08), so a stalled connection waited
/// forever. The CLI's download bar (`unit="iB"`, `:74-80`) is already read by
/// `WhisperProgressParser` as `.downloadingModel`, so this engine now tells the same observers the
/// warm engine tells (F823, F859) — the app then shows the download in the pill, the Dictation tab
/// and the menu, as it does on Apple silicon — and stops the run once the bar has not moved for
/// `downloadStallTimeout`, as F522's window does for the helper. A bar at 100 % ends the download and
/// the window: what openai-whisper does next (hash the file, load it) is not the download's to time.
/// The CLI contract is unchanged.
public final class BatchWhisperDictationEngine: DictationEngine, @unchecked Sendable {
    private let client: LocalWhisperClient
    private let model: WhisperModel
    private let lock = NSLock()
    private var downloadObserver: DictationModelDownloadObserver?
    private var downloadProgressObserver: DictationModelDownloadProgressObserver?

    /// How long the download bar may stand still before the run is stopped — the warm engine's
    /// `downloadStallTimeout` (F522). Internal so a test can shorten it.
    var downloadStallTimeout: TimeInterval = 180

    public init(client: LocalWhisperClient, model: WhisperModel = .turbo) {
        self.client = client
        self.model = model
    }

    public func warmUp() async throws {}

    public func observeModelDownload(_ observer: DictationModelDownloadObserver?) {
        lock.withLock { downloadObserver = observer }
    }

    public func observeModelDownloadProgress(_ observer: DictationModelDownloadProgressObserver?) {
        lock.withLock { downloadProgressObserver = observer }
    }

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
        let (report, stallTimeout) = lock.withLock {
            (CheckpointDownloadReport(observer: downloadObserver, progressObserver: downloadProgressObserver),
             downloadStallTimeout)
        }
        // However the run ends — the reply, the stall, an error, a cancellation — a download that
        // was shown is ended, so the app can never be left showing one (F823's rule).
        defer { report.end() }
        // The stall window is the client's, the one rule meetings use (F901); this engine only reports
        // the download and says the stall in dictation's words (F1023, folded into F1038).
        var client = self.client
        client.downloadStallTimeout = stallTimeout
        let result: TranscriptionResult
        do {
            result = try await client.transcribe(recordingAt: url, options: options) { report.observe($0) }
        } catch LocalWhisperError.modelDownloadStalled(let seconds) {
            throw DictationModelDownloadError(
                "The dictation model download made no progress for \(seconds) seconds and was stopped. "
                    + "Check your connection and try again."
            )
        }
        return DictationResult(
            text: result.text,
            languageCode: result.languageCode,
            noSpeechProb: result.segments.compactMap(\.noSpeechProb).min()
        )
    }

    public func shutdown() {}
}

/// One CLI run's view of its checkpoint download (F860), for the dictation observers: when the
/// download bar appears, its whole percent as it changes, and when it ends. The stall window is
/// `LocalWhisperClient`'s (`ModelDownloadStallWatch`, F901); this kept a second copy of that rule until
/// F1023 (folded into F1038).
private final class CheckpointDownloadReport: @unchecked Sendable {
    private let lock = NSLock()
    private let observer: DictationModelDownloadObserver?
    private let progressObserver: DictationModelDownloadProgressObserver?
    private var downloading = false
    /// A bar reached 100 % (review R6): the download is over. One CLI run downloads one checkpoint, so
    /// later download bars (tqdm's closing redraw) are ignored.
    private var finished = false
    private var lastPercent: Int?

    init(observer: DictationModelDownloadObserver?, progressObserver: DictationModelDownloadProgressObserver?) {
        self.observer = observer
        self.progressObserver = progressObserver
    }

    /// One parsed progress update from the CLI.
    func observe(_ progress: LocalTranscriptionProgress) {
        var started = false
        var ended = false
        var figure: DictationModelDownloadProgress?
        lock.withLock {
            if progress.phase == .downloadingModel {
                guard !finished else { return }
                if !downloading { downloading = true; started = true }
                // Whole percent only: the bar redraws ten times a second, the app needs a percent.
                if let fraction = progress.fractionCompleted {
                    let next = DictationModelDownloadProgress(fractionCompleted: fraction)
                    if next.percent != lastPercent {
                        lastPercent = next.percent
                        figure = next
                    }
                    if next.percent == 100 {
                        finished = true
                        downloading = false
                        ended = true
                    }
                }
            } else if downloading, progress.phase != .preparing, progress.phase != .loadingModel {
                downloading = false
                ended = true
            }
        }
        // Outside the lock, in order: the start before its first figure.
        if started { observer?(true) }
        if let figure { progressObserver?(figure) }
        if ended { observer?(false) }
    }

    /// Ends a download that is still showing. Idempotent.
    func end() {
        let wasDownloading = lock.withLock {
            defer { downloading = false }
            return downloading
        }
        if wasDownloading { observer?(false) }
    }
}
