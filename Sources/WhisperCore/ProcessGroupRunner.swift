import Foundation

public enum ProcessGroupRunnerError: Error, Equatable {
    /// `posix_spawn` itself failed (bad path, permissions); carries its errno.
    case spawnFailed(Int32)
    /// No output for longer than the stall timeout — the tree was killed.
    case stalled(TimeInterval)
}

/// Runs a child process **in its own process group**, streaming its merged stdout+stderr, so that
/// cancelling kills the child *and every descendant it spawned* (F183).
///
/// Two things here are deliberately new work rather than copies of the existing clients:
///
/// 1. **Process-group cancellation.** `ProcessCancellationController` terminates only the direct child,
///    and `LocalSummarizer` documents surviving `afconvert`/`ffmpeg` grandchildren as a known gap. A
///    downloader *always* spawns ffmpeg for audio extraction, so inheriting that gap would orphan a
///    transcode on every cancel. Spawning with `POSIX_SPAWN_SETPGROUP` makes the child a group leader
///    atomically at spawn time (no setpgid race), so `killpg` reaches the whole tree.
/// 2. **A stall timeout.** No one-shot client in this repo has one, and none needs one: a local
///    transcriber that is slow is still making progress. A *network* download stalled on a dead socket
///    hangs forever, so this runner aborts when no output arrives for `stallTimeout`.
public final class ProcessGroupRunner: @unchecked Sendable {
    public struct Outcome: Sendable {
        public let exitStatus: Int32
        public let output: String
    }

    /// Mutable state shared with the reader thread and the stall watchdog.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var output = ""
        private var lastActivity = Date()
        private(set) var stalled = false

        func append(_ text: String) {
            lock.lock()
            output += text
            // Keep the buffer bounded like the other clients do; the tail is what diagnostics need.
            if output.count > 200_000 { output = String(output.suffix(100_000)) }
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
    private var cancelRequested = false

    public init() {}

    /// Records the spawned child and reports whether cancellation was already requested. Synchronous
    /// (not called from an async context) so the lock use is safe under Swift 6 checking.
    private func registerChild(_ pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        childPID = pid
        return cancelRequested
    }

    private func isCancelRequested() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelRequested
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
        lock.lock()
        cancelRequested = true
        let pid = childPID
        lock.unlock()
        if pid > 0 { _ = killpg(pid, SIGTERM) }
    }

    public func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        stallTimeout: TimeInterval,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> Outcome {
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

        if registerChild(pid) { _ = killpg(pid, SIGTERM) }

        let state = State()
        // Blocking reads live on a dedicated queue, never a cooperative thread.
        let readQueue = DispatchQueue(label: "com.whispermeet.process-group-runner.read")
        readQueue.async {
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

        if state.stalled { throw ProcessGroupRunnerError.stalled(stallTimeout) }
        try Task.checkCancellation()
        if isCancelRequested() { throw CancellationError() }

        // Decode wait(2) status: low byte holds the signal when killed, high byte the exit code.
        let exitStatus = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : -(status & 0x7F)
        return Outcome(exitStatus: exitStatus, output: state.snapshot())
    }
}
