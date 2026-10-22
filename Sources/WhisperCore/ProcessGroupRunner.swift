import Foundation

public enum ProcessGroupRunnerError: LocalizedError, Equatable {
    /// `posix_spawn` itself failed (bad path, permissions); carries its errno.
    case spawnFailed(Int32)
    /// No output for longer than the stall timeout — the tree was killed.
    case stalled(TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .spawnFailed(let code):
            let reason = String(cString: strerror(code))
            return "The downloader could not be started: \(reason) (errno \(code))."
        case .stalled(let seconds):
            return "The download stopped responding for \(Int(seconds.rounded())) seconds and was cancelled."
        }
    }
}

/// Runs a child process **in its own process group**, streaming its merged stdout+stderr, so that
/// cancelling kills the child *and every descendant it spawned* (F183).
///
/// Two things here are deliberately new work rather than copies of the existing clients:
///
/// 1. **Process-group cancellation.** A downloader *always* spawns ffmpeg for audio extraction, so a
///    cancel that reached only the direct child would orphan a transcode every time. Spawning with
///    `POSIX_SPAWN_SETPGROUP` makes the child a group leader atomically at spawn time (no setpgid
///    race), so `killpg` reaches the whole tree — explicitly, rather than through Foundation's
///    `Process`, which F153 measured to signal the group too via `terminate()`.
/// 2. **A stall timeout.** The transcription clients have none and need none: a local transcriber
///    that is slow is still making progress. A *network* download stalled on a dead socket hangs
///    forever, so this runner aborts when no output arrives for `stallTimeout`. The local embedder
///    and, since F512, the local summarizer run under it for the same watchdog, with a helper that
///    reports as it works so that silence means stuck rather than slow.
public final class ProcessGroupRunner: @unchecked Sendable {
    public struct Outcome: Sendable {
        public let exitStatus: Int32
        public let output: String
    }

    /// How the captured output will be used, which decides whether it may be truncated.
    public enum OutputUse: Sendable {
        /// Diagnostics only — keep a bounded tail, like the other subprocess clients do.
        case diagnostics
        /// The output IS the result and will be parsed as a whole document, so it must never be
        /// truncated: front-truncating a single-line JSON payload (`yt-dlp --dump-single-json`) leaves
        /// a buffer with no line starting with `{`, which parses as "unreadable" and kills the import.
        case parsedResult
    }

    /// Mutable state shared with the reader thread and the stall watchdog.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var output = ""
        private var lastActivity = Date()
        private(set) var stalled = false
        private let use: OutputUse

        init(use: OutputUse) { self.use = use }

        func append(_ text: String) {
            lock.lock()
            output += text
            // Bound the buffer only when it is diagnostics; a parsed result must stay intact.
            if use == .diagnostics, output.count > 200_000 {
                output = String(output.suffix(100_000))
            }
            lastActivity = Date()
            lock.unlock()
        }

        func secondsSinceActivity() -> TimeInterval {
            lock.lock(); defer { lock.unlock() }
            return Date().timeIntervalSince(lastActivity)
        }

        func markStalled() {
            lock.lock(); stalled = true; lock.unlock()
        }

        func snapshot() -> String {
            lock.lock(); defer { lock.unlock() }
            return output
        }
    }

    private let lock = NSLock()
    private var childPID: pid_t = -1
    /// The signal a stop asked for, or 0 while none has: SIGTERM from `cancel()`, SIGKILL from
    /// `kill()`. Remembered rather than only sent, because a stop asked for while the child is being
    /// spawned finds no pid to signal, and `run` applies it when it records the child. That used to be
    /// a SIGTERM whatever was asked for, so a `kill()` landing in the window was only a SIGTERM (review
    /// of F453). A later `cancel()` never turns a requested SIGKILL back into a SIGTERM.
    private var requestedSignal: Int32 = 0

    public init() {}

    /// Records the spawned child and returns the signal a stop already asked for, or 0. Synchronous
    /// (not called from an async context) so the lock use is safe under Swift 6 checking.
    private func registerChild(_ pid: pid_t) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        childPID = pid
        return requestedSignal
    }

    private func isCancelRequested() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return requestedSignal != 0
    }

    /// Records a stop and returns the child to signal now, or -1 when there is none yet.
    private func requestStop(_ signal: Int32) -> pid_t {
        lock.lock()
        defer { lock.unlock() }
        if requestedSignal != SIGKILL { requestedSignal = signal }
        return childPID
    }

    /// Sends the group the stop already asked for, if any, again. Called only while the exited leader
    /// is unreaped, so `pid` is still this child's group (F1068).
    private func repeatStop(_ pid: pid_t) {
        lock.lock()
        let signal = requestedSignal
        lock.unlock()
        if signal != 0 { _ = killpg(pid, signal) }
    }

    /// Forgets the reaped child so a later `cancel()` cannot signal a **recycled** pid. Once `waitpid`
    /// has returned, the kernel is free to reuse that pid for an unrelated process, and a stale
    /// `killpg` would then terminate somebody else's process group.
    private func forgetChild() {
        lock.lock()
        defer { lock.unlock() }
        childPID = -1
    }

    /// Terminates the entire process group. Safe to call before the child exists (the request is
    /// remembered and applied at spawn) and after it has exited (a no-op).
    public func cancel() {
        let pid = requestStop(SIGTERM)
        if pid > 0 { _ = killpg(pid, SIGTERM) }
    }

    /// Kills the entire process group with SIGKILL, which no process can catch or ignore — for a stop
    /// that must end the run now and whose output is thrown away. `run` waits for the child without a
    /// bound, so `cancel()`'s SIGTERM ends a run only when the child chooses to exit, and ffmpeg 8.1.2
    /// with its input read blocked does not (F453: still running 17.3 s after one SIGTERM). Safe before
    /// the child exists (applied as SIGKILL when it is recorded) and after it has exited (a no-op).
    public func kill() {
        let pid = requestStop(SIGKILL)
        if pid > 0 { _ = killpg(pid, SIGKILL) }
    }

    /// Test seam: awaited after the child is spawned and before it is recorded — the one window in
    /// which a stop finds no pid to signal and is applied by the recording itself. Nil in the app.
    var afterSpawnForTesting: (@Sendable () async -> Void)?

    /// - Parameter returnsOutcomeWhenCancelled: When true, a cancellation that arrives after the child
    ///   was spawned still sends the group SIGTERM, but the run returns the child's `Outcome` rather
    ///   than throwing `CancellationError`, so the caller can tell a child that stopped from one that
    ///   ignored the signal and finished (F654: an installer past its switch-over does exactly that,
    ///   and exits 0). A cancellation before spawn still throws — nothing ran. Default false.
    public func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        stallTimeout: TimeInterval,
        outputUse: OutputUse = .diagnostics,
        returnsOutcomeWhenCancelled: Bool = false,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> Outcome {
        // Never spawn a child for an already-cancelled task: the old `ProcessCancellationController`
        // made launch-vs-cancel one atomic decision, and losing that would let a cancellation that
        // lands just before launch start a process nobody is waiting on.
        try Task.checkCancellation()
        if isCancelRequested() { throw CancellationError() }

        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(executableURL.path)]
        argv.append(contentsOf: arguments.map { strdup($0) })
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            for pointer in argv where pointer != nil { free(pointer) }
            for pointer in envp where pointer != nil { free(pointer) }
        }

        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw ProcessGroupRunnerError.spawnFailed(errno) }
        let readDescriptor = descriptors[0]
        let writeDescriptor = descriptors[1]

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, writeDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, writeDescriptor, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, readDescriptor)
        posix_spawn_file_actions_addclose(&actions, writeDescriptor)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        // Reset every signal to its default disposition in the child. Ignored signals are INHERITED
        // ACROSS EXEC, so a parent that ignores SIGTERM (a GUI app, or the test harness) would otherwise
        // hand the child that same SIG_IGN — `killpg` would then return success while nothing died.
        // Two separate inheritance hazards have to be cleared or the child silently survives `killpg`:
        //
        //  - **Dispositions**: an ignored signal (SIG_IGN) is inherited across exec, so a parent that
        //    ignores SIGTERM hands the child that same SIG_IGN. `SETSIGDEF` resets them to default.
        //  - **Mask**: the signal mask is inherited too, and it is the *spawning thread's* mask that is
        //    copied — Swift-concurrency/libdispatch worker threads run with signals blocked, so without
        //    `SETSIGMASK` the child starts with SIGTERM blocked and `killpg` reports success while
        //    nothing dies. This one is invisible in a plain command-line reproduction and only shows up
        //    when spawning from a Task, which is exactly how this runner is used.
        var defaultedSignals = sigset_t()
        sigfillset(&defaultedSignals)
        posix_spawnattr_setsigdefault(&attributes, &defaultedSignals)
        var unblockedSignals = sigset_t()
        sigemptyset(&unblockedSignals)
        posix_spawnattr_setsigmask(&attributes, &unblockedSignals)
        // The child also becomes the leader of a brand-new group (pgid == its own pid), atomically.
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        )
        posix_spawnattr_setpgroup(&attributes, 0)

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, executableURL.path, &actions, &attributes, argv, envp)
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
        close(writeDescriptor)

        guard spawnResult == 0 else {
            close(readDescriptor)
            throw ProcessGroupRunnerError.spawnFailed(spawnResult)
        }

        if let hook = afterSpawnForTesting { await hook() }
        // A stop asked for before the child was recorded is delivered now, as the signal it asked for.
        let pendingSignal = registerChild(pid)
        if pendingSignal != 0 { _ = killpg(pid, pendingSignal) }

        let state = State(use: outputUse)
        // Blocking reads live on a dedicated queue, never a cooperative thread. The group lets the
        // result wait for EOF before snapshotting — without that join, the child's final bytes (which
        // for a probe are the payload itself) can still be in flight when `waitpid` returns.
        let readGroup = DispatchGroup()
        let readQueue = DispatchQueue(label: "com.whispermeet.process-group-runner.read")
        readQueue.async(group: readGroup) {
            while true {
                var buffer = [UInt8](repeating: 0, count: 4_096)
                let count = read(readDescriptor, &buffer, buffer.count)
                guard count > 0 else { break }
                let text = String(decoding: buffer[0..<count], as: UTF8.self)
                state.append(text)
                onOutput?(text)
            }
            close(readDescriptor)
        }

        let stallWatchdog = Task.detached { [weak self] in
            guard stallTimeout > 0 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                if state.secondsSinceActivity() > stallTimeout {
                    state.markStalled()
                    self?.cancel()
                    return
                }
            }
        }
        defer { stallWatchdog.cancel() }

        let status: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    // Exited, and left unreaped until the stop has been sent again (F1068): a process a
                    // member forked while `killpg` was being delivered was not in the group yet, missed
                    // the signal, and holds the output pipe the drain below waits on. While the leader
                    // is a zombie its pid is still this group's, so the repeat cannot reach a recycled one.
                    var exited = siginfo_t()
                    while waitid(P_PID, id_t(pid), &exited, WEXITED | WNOWAIT) == -1, errno == EINTR {}
                    self.repeatStop(pid)
                    var raw: Int32 = 0
                    waitpid(pid, &raw, 0)
                    continuation.resume(returning: raw)
                }
            }
        } onCancel: {
            self.cancel()
        }
        // The child has been reaped; its pid may be recycled from here on.
        forgetChild()
        stallWatchdog.cancel()
        // Drain to EOF before reading the buffer, so no trailing output is lost.
        await withCheckedContinuation { continuation in
            readGroup.notify(queue: .global()) { continuation.resume() }
        }

        if state.stalled { throw ProcessGroupRunnerError.stalled(stallTimeout) }
        if !returnsOutcomeWhenCancelled {
            try Task.checkCancellation()
            if isCancelRequested() { throw CancellationError() }
        }

        // Decode wait(2) status: low byte holds the signal when killed, high byte the exit code.
        let exitStatus = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : -(status & 0x7F)
        return Outcome(exitStatus: exitStatus, output: state.snapshot())
    }
}
