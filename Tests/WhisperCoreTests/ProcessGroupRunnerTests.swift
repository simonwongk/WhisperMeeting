import Foundation
import Testing
@testable import WhisperCore

// F183 — the two subprocess-lifecycle guarantees the download path needs and no existing client has:
// cancelling kills the whole process tree (not just the direct child), and a silent process is aborted
// by a stall timeout. Both are exercised against real processes.

private func makeScript(_ body: String) throws -> (directory: URL, script: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ProcessGroupRunnerTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("run.sh")
    try body.write(to: script, atomically: true, encoding: .utf8)
    return (directory, script)
}

private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

/// F645 — these two tests used to assert `Date().timeIntervalSince(startedAt) < 15` as a guard against
/// passing for the wrong reason (a stand-in that exits by itself after 30 s). A bound is a comparison
/// of two durations, and the host moves either one. The stand-ins now outlive the cap by a wide margin
/// (120 s against a 30 s cap), so an event inside the cap can only have been caused by the code under
/// test, and every wait polls its own subject under that cap and is required.
private final class Completion: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    func markFinished() { lock.withLock { finished = true } }
    var isFinished: Bool { lock.withLock { finished } }
}

/// Polls `condition` every 5 ms under a 30 s cap and requires it, so a timeout fails as a timeout.
private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    var ticks = 0
    while !condition(), ticks < 6_000 {
        try await Task.sleep(nanoseconds: 5_000_000)
        ticks += 1
    }
    try #require(condition(), "timed out waiting for \(what)")
}

@Test("Cancelling kills the grandchild too, not just the direct child (F183)")
func cancelKillsProcessTree() async throws {
    // The script spawns a long-lived grandchild (like yt-dlp spawning ffmpeg) and reports its pid.
    // 120 s, not 30: the wait below is capped at 30 s, so the tree cannot exit on its own inside it.
    let (directory, script) = try makeScript("""
    sleep 120 &
    echo $! > "$1"
    echo started
    sleep 120
    """)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("child.pid")

    let runner = ProcessGroupRunner()
    let task = Task {
        try await runner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [script.path, pidFile.path],
            environment: ["PATH": "/usr/bin:/bin"],
            stallTimeout: 0 // no stall watchdog — this test is about cancellation
        )
    }

    // Wait for the grandchild to exist. 30 s (it was 10): this is a precondition, and the loop leaves
    // the moment the pid is readable, so the cap only matters to a machine that is slow to spawn.
    var grandchild: pid_t = -1
    for _ in 0..<600 {
        try? await Task.sleep(nanoseconds: 50_000_000)
        if let text = try? String(contentsOf: pidFile, encoding: .utf8),
           let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            grandchild = pid
            break
        }
    }
    #expect(grandchild > 0)
    #expect(isAlive(grandchild))

    // The old test awaited `task.value` here without a bound and then asserted `< 15` on the elapsed
    // time, the guard against passing for the wrong reason (both stand-ins exit by themselves after
    // 30 s). F645: they run for 120 s now and every wait is capped at 30 s, so a run that has
    // returned, and a grandchild that is gone, inside the cap were caused by the cancellation. The
    // `task.value` wait must be capped too — unbounded it would sit out the 120 s and let a cancel
    // that does nothing pass once the script exited by itself.
    let returned = Completion()
    Task {
        _ = try? await task.value
        returned.markFinished()
    }
    runner.cancel()
    var waited = 0
    while !returned.isFinished, waited < 6_000 {
        try await Task.sleep(nanoseconds: 5_000_000)
        waited += 1
    }
    let cancelled = returned.isFinished

    // Give the signal a moment to be delivered to the whole group: up to 30 s (it was 5).
    var died = false
    if cancelled {
        for _ in 0..<600 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if !isAlive(grandchild) { died = true; break }
        }
    }
    // A run that failed must not leave the stand-ins sleeping for two minutes: signal the
    // grandchild's whole group (the script leads it), never our own.
    if !died, grandchild > 0 {
        let group = getpgid(grandchild)
        if group > 0, group != getpgrp() { _ = killpg(group, SIGKILL) } else { _ = kill(grandchild, SIGKILL) }
    }
    try #require(cancelled, "cancel() did not end the run")
    #expect(died, "the grandchild survived cancellation — the process group was not killed")
}

@Test("A silent process is aborted by the stall timeout (F183)")
func stallTimeoutAborts() async throws {
    let (directory, script) = try makeScript("sleep 120\n")
    defer { try? FileManager.default.removeItem(at: directory) }

    let runner = ProcessGroupRunner()
    // A failed run must not leave the silent script sleeping for two minutes. Declared before the
    // run, so it also covers a run that never returns.
    defer { runner.cancel() }
    let completion = Completion()
    let run = Task {
        defer { completion.markFinished() }
        return try await runner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [script.path],
            environment: ["PATH": "/usr/bin:/bin"],
            stallTimeout: 1
        )
    }
    // The abort must come from the watchdog, not from the script finishing on its own: the script
    // sleeps for 120 s and the wait is capped at 30 s, so a run that has returned inside the cap was
    // aborted, and the error below says by what. A watchdog that never fires fails on this wait
    // instead of hanging the suite.
    try await waitUntil("the stall watchdog to abort the silent run") { completion.isFinished }
    await #expect(throws: ProcessGroupRunnerError.stalled(1)) {
        _ = try await run.value
    }
}

@Test("A large single-line payload survives intact when the output IS the result (F183)")
func parsedResultOutputIsNotTruncated() async throws {
    // The probe's JSON arrives as ONE line well past the diagnostics cap. Front-truncating it leaves a
    // buffer with no line starting with "{", which parses as "unreadable" and kills the import — so
    // `.parsedResult` must keep the payload whole.
    let (directory, script) = try makeScript(#"""
    printf '{"title":"'
    /usr/bin/awk 'BEGIN { while (i++ < 300000) printf "a" }'
    printf '"}\n'
    """#)
    defer { try? FileManager.default.removeItem(at: directory) }

    let outcome = try await ProcessGroupRunner().run(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path],
        environment: ["PATH": "/usr/bin:/bin"],
        stallTimeout: 60,
        outputUse: .parsedResult
    )
    #expect(outcome.output.count > 300_000)
    #expect(outcome.output.hasPrefix("{"))       // the head survived — parseProbe can find the object
    #expect(outcome.output.contains("\"}"))      // and so did the tail (the reader thread was joined)
}

@Test("A normal run streams its output and reports its exit status (F183)")
func normalRunStreamsOutput() async throws {
    let (directory, script) = try makeScript("echo hello; exit 3\n")
    defer { try? FileManager.default.removeItem(at: directory) }

    let runner = ProcessGroupRunner()
    let outcome = try await runner.run(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path],
        environment: ["PATH": "/usr/bin:/bin"],
        stallTimeout: 30
    )
    #expect(outcome.output.contains("hello"))
    #expect(outcome.exitStatus == 3)
}

// F654 — an installer past its switch-over ignores the signal and finishes; its caller has to see
// that it exited 0 rather than a bare `CancellationError`, or a completed update reads "cancelled".

private func waitForFile(_ url: URL) async throws {
    let deadline = Date().addingTimeInterval(30)
    while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    try #require(FileManager.default.fileExists(atPath: url.path), "timed out waiting for \(url.lastPathComponent)")
}

@Test("With returnsOutcomeWhenCancelled, a child that outlives the cancel reports its exit status (F654)")
func cancelledRunReportsTheOutcomeWhenAsked() async throws {
    let (directory, script) = try makeScript("""
    trap '' TERM
    echo started > "$1"
    i=0; while [ ! -e "$2" ] && [ $i -lt 600 ]; do sleep 0.05; i=$((i + 1)); done
    exit 0
    """)
    defer { try? FileManager.default.removeItem(at: directory) }
    let started = directory.appendingPathComponent("started")
    let release = directory.appendingPathComponent("release")

    let task = Task {
        try await ProcessGroupRunner().run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [script.path, started.path, release.path],
            environment: ["PATH": "/usr/bin:/bin"],
            stallTimeout: 0,
            returnsOutcomeWhenCancelled: true
        )
    }
    try await waitForFile(started)
    task.cancel()
    try Data().write(to: release)
    let outcome = try await task.value
    #expect(outcome.exitStatus == 0)
}

@Test("With returnsOutcomeWhenCancelled, a child the cancel stops reports a non-zero status (F654)")
func cancelledRunReportsTheSignalWhenAsked() async throws {
    let (directory, script) = try makeScript("""
    echo started > "$1"
    sleep 30
    """)
    defer { try? FileManager.default.removeItem(at: directory) }
    let started = directory.appendingPathComponent("started")

    let task = Task {
        try await ProcessGroupRunner().run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [script.path, started.path],
            environment: ["PATH": "/usr/bin:/bin"],
            stallTimeout: 0,
            returnsOutcomeWhenCancelled: true
        )
    }
    try await waitForFile(started)
    task.cancel()
    let outcome = try await task.value
    #expect(outcome.exitStatus != 0)
}
