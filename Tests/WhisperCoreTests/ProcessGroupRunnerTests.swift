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

@Test("Cancelling kills the grandchild too, not just the direct child (F183)")
func cancelKillsProcessTree() async throws {
    // The script spawns a long-lived grandchild (like yt-dlp spawning ffmpeg) and reports its pid.
    let (directory, script) = try makeScript("""
    sleep 30 &
    echo $! > "$1"
    echo started
    sleep 30
    """)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("child.pid")

    let runner = ProcessGroupRunner()
    let startedAt = Date()
    let task = Task {
        try await runner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [script.path, pidFile.path],
            environment: ["PATH": "/usr/bin:/bin"],
            stallTimeout: 0 // no stall watchdog — this test is about cancellation
        )
    }

    // Wait for the grandchild to exist.
    var grandchild: pid_t = -1
    for _ in 0..<200 {
        try? await Task.sleep(nanoseconds: 50_000_000)
        if let text = try? String(contentsOf: pidFile, encoding: .utf8),
           let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            grandchild = pid
            break
        }
    }
    #expect(grandchild > 0)
    #expect(isAlive(grandchild))

    runner.cancel()
    _ = try? await task.value

    // Give the signal a moment to be delivered to the whole group.
    var died = false
    for _ in 0..<100 {
        try? await Task.sleep(nanoseconds: 50_000_000)
        if !isAlive(grandchild) { died = true; break }
    }
    #expect(died, "the grandchild survived cancellation — the process group was not killed")
    // Without this, the test would pass for the wrong reason: if killpg did nothing, the scripts would
    // simply run to completion and everything would "die" ~30 s later.
    #expect(
        Date().timeIntervalSince(startedAt) < 15,
        "cancellation did not take effect promptly — the tree likely exited on its own"
    )
}

@Test("A silent process is aborted by the stall timeout (F183)")
func stallTimeoutAborts() async throws {
    let (directory, script) = try makeScript("sleep 30\n")
    defer { try? FileManager.default.removeItem(at: directory) }

    let runner = ProcessGroupRunner()
    let startedAt = Date()
    await #expect(throws: ProcessGroupRunnerError.stalled(1)) {
        try await runner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [script.path],
            environment: ["PATH": "/usr/bin:/bin"],
            stallTimeout: 1
        )
    }
    // The abort must come from the watchdog, not from the script finishing on its own.
    #expect(Date().timeIntervalSince(startedAt) < 15, "the stall timeout did not actually abort the run")
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
