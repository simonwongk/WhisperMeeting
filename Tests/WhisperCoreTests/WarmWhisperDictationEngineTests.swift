import Darwin
import Testing
import Foundation
@testable import WhisperCore

/// Reads a pid a test helper wrote, or nil while the file exists but is still empty — shell and
/// Python both create the file before the write lands, so existence alone does not mean readable.
private func recordedPID(_ url: URL) -> Int32? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
}

private final class EvictionCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func markFinished() {
        lock.withLock { finished = true }
    }

    var isFinished: Bool {
        lock.withLock { finished }
    }
}

@Test("shutdown() interrupts in-flight warm-up instead of waiting for the process to finish")
func warmDictationEngineShutdownInterruptsInFlightWork() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("WarmEngineShutdown-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    // A stand-in "helper" that stays alive and silent: warmUp() parks in readLine waiting for a
    // {"ready":true} line that never comes. `exec` so the process we terminate is the one holding
    // stdout — no orphaned child keeps the pipe open after termination.
    let script = tmp.appendingPathComponent("stall.sh")
    try "exec sleep 20\n".write(to: script, atomically: true, encoding: .utf8)

    let engine = WarmWhisperDictationEngine(
        python: URL(fileURLWithPath: "/bin/sh"),
        script: script,
        modelDirectory: tmp
    )

    let started = Date()
    let warm = Task { try await engine.warmUp() }
    // Let ensureRunning() spawn the process and block in readLine before we tear down.
    try await Task.sleep(for: .milliseconds(400))
    engine.shutdown()
    _ = await warm.result // warmUp is expected to throw once the helper is torn down.
    let elapsed = Date().timeIntervalSince(started)

    // Off-queue termination unblocks the parked read immediately. The bug (terminate queued behind
    // the blocking operation) would not return until the stub exited on its own ~20s later.
    #expect(elapsed < 8)
}

@Test("retire() waits for an in-flight helper to exit before model replacement")
func warmDictationEngineRetirementDrainsProcessWork() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("WarmEngineRetire-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let script = tmp.appendingPathComponent("stall.sh")
    try "exec sleep 20\n".write(to: script, atomically: true, encoding: .utf8)
    let engine = WarmWhisperDictationEngine(
        python: URL(fileURLWithPath: "/bin/sh"),
        script: script,
        modelDirectory: tmp
    )

    let warm = Task { try await engine.warmUp() }
    try await Task.sleep(for: .milliseconds(400))
    let startedRetiring = Date()
    await engine.retire()
    _ = await warm.result

    #expect(Date().timeIntervalSince(startedRetiring) < 8)
}

@Test("retire() waits for an idle helper process to actually exit")
func warmDictationEngineRetirementWaitsForIdleProcessExit() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("WarmEngineIdleRetire-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let marker = tmp.appendingPathComponent("helper-exited")
    let script = tmp.appendingPathComponent("ready-then-delay-exit.sh")
    let helper = """
    trap 'sleep 1; touch "\(marker.path)"; exit 0' TERM
    printf '{"ready":true}\\n'
    while :; do sleep 1; done
    """
    try helper.write(to: script, atomically: true, encoding: .utf8)
    let engine = WarmWhisperDictationEngine(
        python: URL(fileURLWithPath: "/bin/sh"),
        script: script,
        modelDirectory: tmp
    )

    try await engine.warmUp()
    let startedRetiring = Date()
    await engine.retire()
    let elapsed = Date().timeIntervalSince(startedRetiring)

    #expect(FileManager.default.fileExists(atPath: marker.path))
    #expect(elapsed >= 0.8)
    #expect(elapsed < 8)
}

@Test("evict() waits for an idle helper to exit but permits a later rewarm (F206)")
func warmDictationEngineEvictionWaitsAndCanRewarm() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("WarmEngineEvict-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let marker = tmp.appendingPathComponent("helper-exited")
    let script = tmp.appendingPathComponent("ready-then-delay-exit.sh")
    let helper = """
    trap 'sleep 1; touch "\(marker.path)"; exit 0' TERM
    printf '{"ready":true}\\n'
    while :; do sleep 1; done
    """
    try helper.write(to: script, atomically: true, encoding: .utf8)
    let engine = WarmWhisperDictationEngine(
        python: URL(fileURLWithPath: "/bin/sh"),
        script: script,
        modelDirectory: tmp
    )

    try await engine.warmUp()
    let started = Date()
    await engine.evict()
    let elapsed = Date().timeIntervalSince(started)

    #expect(FileManager.default.fileExists(atPath: marker.path))
    #expect(elapsed >= 0.8)
    #expect(elapsed < 8)
    // Unlike a model replacement, meeting preparation is temporary: the next hotkey can warm the
    // same engine instance again.
    try await engine.warmUp()
    engine.shutdown()
}

@Test("evict force-stops a TERM-ignoring helper even while its stdout read is blocked (F206)")
func warmDictationEngineEvictionForceStopsWedgedHelper() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("WarmEngineForceEvict-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let pidFile = tmp.appendingPathComponent("helper.pid")
    let childPIDFile = tmp.appendingPathComponent("helper-child.pid")
    let script = tmp.appendingPathComponent("ignore-term.sh")
    // Keep both the helper and a descendant alive after TERM. The descendant deliberately retains
    // stdout, matching a helper-launched decoder: a direct SIGKILL of only the helper cannot
    // unblock `availableData`; the process-group escalation must kill both.
    // The descendant must be a separate `sh -c` child, not a `( ... ) &` subshell: in POSIX sh
    // `$$` inside a subshell still expands to the PARENT shell's pid, so a subshell could not
    // record its own pid and this test's emergency cleanup would have no way to reach it.
    let helper = """
    trap '' TERM
    printf '%s' "$$" > "\(pidFile.path)"
    /bin/sh -c 'trap "" TERM; printf "%s" "$$" > "\(childPIDFile.path)"; \
    while :; do sleep 1 < /dev/null > /dev/null 2>&1; done' &
    while :; do sleep 1 < /dev/null > /dev/null 2>&1; done
    """
    try helper.write(to: script, atomically: true, encoding: .utf8)

    let engine = WarmWhisperDictationEngine(
        python: URL(fileURLWithPath: "/bin/sh"),
        script: script,
        modelDirectory: tmp
    )
    defer { engine.shutdown() }
    // Keep `warmUp()` blocked inside `stdout.availableData`. A helper that's already ready lets
    // queued cleanup schedule its old SIGKILL fallback, which is not the failure mode here.
    let warm = Task { try await engine.warmUp() }
    // Wait for a readable pid, not merely for the file: `> "$file"` creates it empty before printf
    // writes. Reading "" here would leave the emergency cleanup below with no pid to signal, and a
    // surviving TERM-ignoring descendant parks this suite on a read that never ends.
    for _ in 0..<200 where recordedPID(pidFile) == nil || recordedPID(childPIDFile) == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(recordedPID(pidFile) != nil)
    #expect(recordedPID(childPIDFile) != nil)

    let completion = EvictionCompletion()
    let eviction = Task {
        await engine.evict()
        completion.markFinished()
    }

    // The red proof intentionally cleans the test helper up itself if production has no
    // off-queue SIGKILL fallback yet. `#expect` records the failure but continues to this cleanup.
    for _ in 0..<140 where !completion.isFinished {
        try await Task.sleep(for: .milliseconds(50))
    }
    let finishedWithoutManualKill = completion.isFinished
    // Clean up before recording the red expectation: a failure must never leave an intentionally
    // TERM-ignoring descendant alive if the testing library stops executing this function early.
    // Signal every recorded pid directly rather than the process group: production's escalation
    // may already have reaped the group leader, and `getpgid` on a dead leader cannot name the
    // surviving tree. Missing the descendant here parks the suite on a read that never ends.
    if !finishedWithoutManualKill {
        for pidRecord in [pidFile, childPIDFile] {
            guard let pid = recordedPID(pidRecord) else { continue }
            _ = Darwin.kill(pid, SIGKILL)
        }
    }
    #expect(finishedWithoutManualKill)
    await eviction.value
    _ = await warm.result
}

@Test("A helper that dies during start surfaces its stderr in the error")
func warmDictationEngineSurfacesStderrOnFailure() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("WarmEngineStderr-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    // Emit a recognizable line to stderr, pause so the drain captures it, then exit (closing stdout
    // so warmUp's readLine sees EOF and reports a failure). Mimics an early MLX import traceback.
    let script = tmp.appendingPathComponent("boom.sh")
    try "echo MLX-IMPORT-BOOM 1>&2\nsleep 0.3\nexit 1\n".write(to: script, atomically: true, encoding: .utf8)

    let engine = WarmWhisperDictationEngine(
        python: URL(fileURLWithPath: "/bin/sh"),
        script: script,
        modelDirectory: tmp
    )
    defer { engine.shutdown() }

    do {
        try await engine.warmUp()
        Issue.record("expected warmUp to throw")
    } catch {
        #expect("\(error)".contains("MLX-IMPORT-BOOM"))
    }
}

@Test("Warm Qwen dictation engine launches the local model and speaks the shared protocol")
func warmQwenDictationEngineUsesLocalModel() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("WarmQwenEngine-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let script = tmp.appendingPathComponent("qwen-stub.sh")
    let helper = """
    test "$1" = "--model" || { echo "missing --model" >&2; exit 2; }
    test "$2" = "\(tmp.path)" || { echo "wrong model path" >&2; exit 2; }
    printf '{"ready":true}\\n'
    IFS= read -r request
    printf '{"text":"qwen result","language":"English","error":null}\\n'
    """
    try helper.write(to: script, atomically: true, encoding: .utf8)

    let engine = WarmQwenDictationEngine(
        python: URL(fileURLWithPath: "/bin/sh"),
        script: script,
        modelDirectory: tmp
    )
    defer { engine.shutdown() }

    let result = try await engine.transcribe(
        wavAt: tmp.appendingPathComponent("shared.wav"),
        language: .english,
        initialPrompt: nil
    )

    #expect(result.text == "qwen result")
    #expect(result.languageCode == "English")
}
