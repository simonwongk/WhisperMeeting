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

// F645 — these tests used to assert `elapsed < 8` after the operation returned; the two in-flight
// ones against a stand-in helper that exits by itself after 20 s. That made "slow" a property of the
// host (with 11 CPU hogs running, the idle-helper tests below took 2.0 s around a helper trap that
// sleeps 1 s) and made the in-flight discrimination a race between two durations. A wait now polls
// the SUBJECT under a wall-clock cap that only a genuine hang reaches, and `#require`s it, so a hang
// fails on the wait; and the in-flight helper cannot exit on its own until the test releases it, so
// "the operation returned" can only mean the engine ended it.

/// Polls `condition` under a 30 s cap and requires it, so a timeout fails as a timeout.
private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    var ticks = 0
    while !condition(), ticks < 6_000 {
        try await Task.sleep(nanoseconds: 5_000_000)
        ticks += 1
    }
    try #require(condition(), "timed out waiting for \(what)")
}

/// Runs `operation` and reports whether it finished inside the 30 s cap. The operation itself may
/// be parked in a blocking call that cancellation cannot reach, so it runs unstructured and is
/// polled rather than awaited: a hang then fails the caller's `#require` instead of hanging the suite.
private func finishesWithinCap(_ operation: @escaping @Sendable () async -> Void) async throws -> Bool {
    let completion = EvictionCompletion()
    Task {
        await operation()
        completion.markFinished()
    }
    var ticks = 0
    while !completion.isFinished, ticks < 6_000 {
        try await Task.sleep(nanoseconds: 5_000_000)
        ticks += 1
    }
    return completion.isFinished
}

/// A stand-in helper that records its pid and then stays alive and silent until `release` exists or
/// its directory is gone. `exec sleep N` would exit on its own after N seconds, which is what the
/// old `< 8` bound was racing; this one only ends when the engine ends it (or the test releases it).
private func writeParkedHelper(in directory: URL, pidFile: URL, release: URL) throws -> URL {
    let script = directory.appendingPathComponent("parked.sh")
    let helper = """
    printf '%s' "$$" > "\(pidFile.path)"
    while [ -d "\(directory.path)" ] && [ ! -e "\(release.path)" ]; do sleep 0.05; done
    """
    try helper.write(to: script, atomically: true, encoding: .utf8)
    return script
}

// F647 — `warmDictationEngineEvictionWaitsAndCanRewarm` failed once in a full run with `evict()` returning
// in 7 ms while the marker existed, against a stand-in whose TERM trap was `sleep 1; touch marker; exit 0`.
// `evict()` was not at fault, and no window was found in which it returns before the helper has exited
// (600 evict-versus-warm-up races at random offsets: no helper outlived `evict()`; see the F647 log
// entry): the stand-in was.
// `Process.terminate()` signals the helper's whole process group, not just its pid, and `evict()` calls it
// twice (once off the queue, once from the queued cleanup). The stand-in's whole delay was `sleep`
// children, so which of them the two group signals killed — the loop's, the trap's, or both — depended on
// how far apart the two calls landed, and when both died the "slow" exit finished in milliseconds.
//
// This stand-in cannot be shortened by any number of terminates: its exit is gated on a file the test
// creates, and the `sleep` children only pace a poll that re-checks that file. It also reports when it was
// told to stop and how long it has stayed alive since, so "evict() is still waiting" is read off the
// helper's own progress and not off a clock.
private struct SlowExitHelper {
    let script: URL
    let pidFile: URL
    /// Created by the TERM trap when the helper is told to stop.
    let termReceived: URL
    /// One byte appended per 50 ms poll of the trap's wait loop.
    let parked: URL
    /// The test creates this to let the helper finish exiting.
    let release: URL
    /// Created just before `exit 0`, so it exists only if the engine waited for the exit.
    let exited: URL

    var parkedPolls: Int {
        ((try? FileManager.default.attributesOfItem(atPath: parked.path)[.size]) as? NSNumber)?.intValue ?? 0
    }
    var wasToldToStop: Bool { FileManager.default.fileExists(atPath: termReceived.path) }
    var hasExited: Bool { FileManager.default.fileExists(atPath: exited.path) }
}

private func writeSlowExitHelper(in directory: URL) throws -> SlowExitHelper {
    let helper = SlowExitHelper(
        script: directory.appendingPathComponent("ready-then-slow-exit.sh"),
        pidFile: directory.appendingPathComponent("helper.pid"),
        termReceived: directory.appendingPathComponent("term-received"),
        parked: directory.appendingPathComponent("parked"),
        release: directory.appendingPathComponent("release"),
        exited: directory.appendingPathComponent("helper-exited")
    )
    // `[ -d directory ]` ends the wait if the test's directory is cleaned up with the helper still
    // parked, so a failing run cannot leave it polling. The trap body is idempotent on purpose: a
    // further TERM during the wait may re-enter it, and re-entering must only keep waiting.
    let text = """
    printf '%s' "$$" > "\(helper.pidFile.path)"
    trap 'touch "\(helper.termReceived.path)"; \
    while [ -d "\(directory.path)" ] && [ ! -e "\(helper.release.path)" ]; do \
    printf . >> "\(helper.parked.path)"; sleep 0.05; done; \
    touch "\(helper.exited.path)"; exit 0' TERM
    printf '{"ready":true}\\n'
    while :; do sleep 0.05; done
    """
    try text.write(to: helper.script, atomically: true, encoding: .utf8)
    return helper
}

@Test("shutdown() interrupts in-flight warm-up instead of waiting for the process to finish")
func warmDictationEngineShutdownInterruptsInFlightWork() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("WarmEngineShutdown-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    // A stand-in "helper" that stays alive and silent: warmUp() parks in readLine waiting for a
    // {"ready":true} line that never comes, and the helper cannot exit until the test releases it,
    // so "warmUp returned" can only mean shutdown() interrupted it. `Process.terminate()` signals the
    // helper's whole process group (F647), so its polling `sleep` children end with the shell.
    let pidFile = tmp.appendingPathComponent("helper.pid")
    let release = tmp.appendingPathComponent("release")
    let script = try writeParkedHelper(in: tmp, pidFile: pidFile, release: release)
    // Declared after the directory's cleanup, so it runs first: a failing run must not leave the
    // helper polling.
    defer { try? Data().write(to: release) }

    let engine = WarmWhisperDictationEngine(
        python: URL(fileURLWithPath: "/bin/sh"),
        script: script,
        modelDirectory: tmp
    )

    let warm = Task { try await engine.warmUp() }
    // Let ensureRunning() spawn the process before we tear down: the helper recording its pid is the
    // fact that says so, where a fixed 400 ms sleep only guessed at it.
    try await waitUntil("the helper to start") { recordedPID(pidFile) != nil }
    engine.shutdown()

    // Off-queue termination unblocks the parked read immediately. The bug (terminate queued behind
    // the blocking operation) leaves warmUp parked until the read's own 1,800 s timeout, so it would
    // never finish inside the cap. warmUp is expected to throw once the helper is torn down.
    let interrupted = try await finishesWithinCap { _ = await warm.result }
    try #require(interrupted, "shutdown() left the in-flight warm-up parked in its read")
}

@Test("retire() waits for an in-flight helper to exit before model replacement")
func warmDictationEngineRetirementDrainsProcessWork() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("WarmEngineRetire-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let pidFile = tmp.appendingPathComponent("helper.pid")
    let release = tmp.appendingPathComponent("release")
    let script = try writeParkedHelper(in: tmp, pidFile: pidFile, release: release)
    defer { try? Data().write(to: release) } // runs before the directory's cleanup above
    let engine = WarmWhisperDictationEngine(
        python: URL(fileURLWithPath: "/bin/sh"),
        script: script,
        modelDirectory: tmp
    )

    let warm = Task { try await engine.warmUp() }
    try await waitUntil("the helper to start") { recordedPID(pidFile) != nil }
    let helperPID = try #require(recordedPID(pidFile))
    let retired = try await finishesWithinCap { await engine.retire() }
    try #require(retired, "retire() did not return while the helper was parked in an in-flight warm-up")
    _ = await warm.result

    // The claim is that retire() WAITS for the exit: the helper it was asked to drain is gone — not
    // merely signalled — by the time it returns.
    #expect(Darwin.kill(helperPID, 0) != 0, "the helper was still alive when retire() returned")
}

@Test("retire() waits for an idle helper process to actually exit")
func warmDictationEngineRetirementWaitsForIdleProcessExit() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("WarmEngineIdleRetire-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let helper = try writeSlowExitHelper(in: tmp)
    // Declared after the directory's cleanup, so it runs first: a failing run must not leave the
    // helper polling.
    defer { try? Data().write(to: helper.release) }
    let engine = WarmWhisperDictationEngine(
        python: URL(fileURLWithPath: "/bin/sh"),
        script: helper.script,
        modelDirectory: tmp
    )

    try await engine.warmUp()
    let helperPID = try #require(recordedPID(helper.pidFile))
    let completion = EvictionCompletion()
    let retirement = Task {
        await engine.retire()
        completion.markFinished()
    }

    // F647: the helper is told to stop, then stays alive on its own say-so for five polls of its
    // exit. retire() returning in that interval can only mean it did not wait. The helper's progress
    // is the clock, so a loaded machine lengthens the wait and never shortens it.
    try await waitUntil("the helper to be told to stop") { helper.wasToldToStop }
    try await waitUntil("the helper to stay alive through five polls of its exit") { helper.parkedPolls >= 5 }
    #expect(!completion.isFinished, "retire() returned while the helper was still running its exit")
    #expect(Darwin.kill(helperPID, 0) == 0, "the helper was gone before the test let it exit")

    try Data().write(to: helper.release)
    try await waitUntil("retire() to return once the helper may exit") { completion.isFinished }
    await retirement.value
    // The marker is created just before `exit 0`: it exists only if retire() waited for the exit.
    #expect(helper.hasExited)
    #expect(Darwin.kill(helperPID, 0) != 0, "the helper was still alive when retire() returned")
}

@Test("evict() waits for an idle helper to exit but permits a later rewarm (F206)")
func warmDictationEngineEvictionWaitsAndCanRewarm() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("WarmEngineEvict-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let helper = try writeSlowExitHelper(in: tmp)
    defer { try? Data().write(to: helper.release) } // runs before the directory's cleanup above
    let engine = WarmWhisperDictationEngine(
        python: URL(fileURLWithPath: "/bin/sh"),
        script: helper.script,
        modelDirectory: tmp
    )

    try await engine.warmUp()
    let helperPID = try #require(recordedPID(helper.pidFile))
    let completion = EvictionCompletion()
    let eviction = Task {
        await engine.evict()
        completion.markFinished()
    }

    // F647: as in the retire() test above, the helper's own progress says evict() is still waiting.
    try await waitUntil("the helper to be told to stop") { helper.wasToldToStop }
    try await waitUntil("the helper to stay alive through five polls of its exit") { helper.parkedPolls >= 5 }
    #expect(!completion.isFinished, "evict() returned while the helper was still running its exit")
    #expect(Darwin.kill(helperPID, 0) == 0, "the helper was gone before the test let it exit")

    try Data().write(to: helper.release)
    try await waitUntil("evict() to return once the helper may exit") { completion.isFinished }
    await eviction.value
    #expect(helper.hasExited)
    #expect(Darwin.kill(helperPID, 0) != 0, "the helper was still alive when evict() returned")
    // Unlike a model replacement, meeting preparation is temporary: the next hotkey can warm the
    // same engine instance again.
    try await engine.warmUp()
    engine.shutdown()
}

@Test("evict() keeps waiting for a helper that is told to stop again while it is still exiting (F647)")
func warmDictationEngineEvictionSurvivesAFurtherTerminate() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("WarmEngineEvictTwice-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let helper = try writeSlowExitHelper(in: tmp)
    defer { try? Data().write(to: helper.release) }
    let engine = WarmWhisperDictationEngine(
        python: URL(fileURLWithPath: "/bin/sh"),
        script: helper.script,
        modelDirectory: tmp
    )

    try await engine.warmUp()
    let helperPID = try #require(recordedPID(helper.pidFile))
    let completion = EvictionCompletion()
    let eviction = Task {
        await engine.evict()
        completion.markFinished()
    }
    try await waitUntil("the helper to be told to stop") { helper.wasToldToStop }
    try await waitUntil("the helper to stay alive through five polls of its exit") { helper.parkedPolls >= 5 }

    // A further terminate while the helper is mid-exit. `Process.terminate()` signals the helper's
    // whole process group, so this kills the `sleep` the helper is polling with; evict() has to keep
    // waiting anyway, because the helper's exit is not made of those sleeps. This is the signal a
    // load-delayed queue hop inside evict() itself delivers, and it is what shortened the old
    // stand-in's exit to milliseconds. It is also a real sequence: shutdown() during an eviction.
    let pollsBefore = helper.parkedPolls
    engine.shutdown()
    try await waitUntil("the helper to keep polling after the second terminate") {
        helper.parkedPolls >= pollsBefore + 5
    }
    #expect(!completion.isFinished, "evict() returned when a further terminate hit the exiting helper")
    #expect(Darwin.kill(helperPID, 0) == 0, "the helper was gone before the test let it exit")

    try Data().write(to: helper.release)
    try await waitUntil("evict() to return once the helper may exit") { completion.isFinished }
    await eviction.value
    #expect(helper.hasExited)
    #expect(Darwin.kill(helperPID, 0) != 0, "the helper was still alive when evict() returned")
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
    // F645: the cap is 30 s (it was 2 s), because this is a precondition and a shell spawn on a
    // loaded machine can be slow; the loop leaves the moment both pids are readable, so a generous
    // cap costs nothing when they are.
    for _ in 0..<3_000 where recordedPID(pidFile) == nil || recordedPID(childPIDFile) == nil {
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
    // F645: 30 s, not 7. Production's own SIGKILL escalation fires 5 s after the eviction request
    // (`requestHelperTermination`), so a 7 s cap left 2 s for a loaded machine to deliver the kill
    // and unwind the eviction; it passed at 5.1–5.3 s with 11 CPU hogs running. Only the failing
    // case waits the full cap.
    for _ in 0..<600 where !completion.isFinished {
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
    // F447: the helper echoes the pinned name it was sent; the result carries the code the app
    // compares on. This used to pin "English", which was the defect written down as a contract.
    #expect(result.languageCode == "en")
}

// F522 — the first Quick Dictation model download is 1.6 GB and the helper used to be given a flat
// 1 800 s to print `{"ready":true}`, so a link slower than ~7 Mbit/s could never finish, however
// steadily it was progressing. The helper now prints `{"downloading":true}` lines as bytes arrive,
// and while it does the wait is "no progress for `downloadStallTimeout`" instead. The windows are
// shortened here, and every wait is a poll of the subject under a 30 s wall-clock cap that is
// `#require`d (F645's rule). The one elapsed-time condition is the claim itself — that a helper which
// keeps reporting outlives the flat limit — and it is the test that waits for it, not the helper.

private final class ThrownMessage: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func set(_ message: String) { lock.withLock { text = message } }
    var value: String { lock.withLock { text } }
}

@Test("A helper reporting download progress is not killed by the flat warm-up limit (F522)")
func warmDictationEngineDownloadHeartbeatsOutliveTheFlatWarmUpLimit() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("WarmEngineDownloadProgress-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    // The helper reports progress until the test releases it, so it can only be stopped by the
    // engine; the test lets the flat limit pass twice over and only then releases it. The heartbeats
    // are protocol-shaped JSON objects, which `readLine` used to return as the reply.
    let release = tmp.appendingPathComponent("release")
    defer { try? Data().write(to: release) } // a failing run must not leave the helper polling
    let script = tmp.appendingPathComponent("downloading.sh")
    let helper = """
    printf '{"downloading":true}\\n'
    while [ -d "\(tmp.path)" ] && [ ! -e "\(release.path)" ]; do
      sleep 0.25
      printf '{"downloading":true}\\n'
    done
    printf '{"downloading":false}\\n'
    printf '{"ready":true}\\n'
    IFS= read -r request
    """
    try helper.write(to: script, atomically: true, encoding: .utf8)

    let engine = WarmWhisperDictationEngine(
        python: URL(fileURLWithPath: "/bin/sh"),
        script: script,
        modelDirectory: tmp
    )
    defer { engine.shutdown() }
    engine.warmUpTimeout = 5
    engine.downloadStallTimeout = 60 // far above the 0.25 s heartbeat gap: only a real stall reaches it

    let completion = EvictionCompletion()
    let outcome = ThrownMessage()
    Task {
        do { try await engine.warmUp() } catch { outcome.set("\(error)") }
        completion.markFinished()
    }
    let began = ContinuousClock.now
    try await waitUntil("the flat warm-up limit to pass twice over") {
        completion.isFinished || ContinuousClock.now - began > .seconds(10)
    }
    #expect(!completion.isFinished, "the warm-up ended while the helper was still reporting progress: \(outcome.value)")

    try Data().write(to: release)
    try await waitUntil("the warm-up to finish once released") { completion.isFinished }
    #expect(outcome.value.isEmpty, "the warm-up failed instead of finishing: \(outcome.value)")
}

@Test("A download that stops reporting progress is stopped, and the error says why (F522)")
func warmDictationEngineStalledDownloadIsStoppedAndNamed() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("WarmEngineDownloadStall-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    // One heartbeat, then silence. The helper cannot exit by itself until the test releases it, so
    // an error can only mean the engine stopped it.
    let release = tmp.appendingPathComponent("release")
    defer { try? Data().write(to: release) }
    let script = tmp.appendingPathComponent("stalled.sh")
    let helper = """
    printf '{"downloading":true}\\n'
    while [ -d "\(tmp.path)" ] && [ ! -e "\(release.path)" ]; do sleep 0.05; done
    """
    try helper.write(to: script, atomically: true, encoding: .utf8)

    let engine = WarmWhisperDictationEngine(
        python: URL(fileURLWithPath: "/bin/sh"),
        script: script,
        modelDirectory: tmp
    )
    defer { engine.shutdown() }
    engine.warmUpTimeout = 600 // the flat budget must not be what ends this
    engine.downloadStallTimeout = 1

    let outcome = ThrownMessage()
    let finished = try await finishesWithinCap {
        do {
            try await engine.warmUp()
            outcome.set("warmUp returned without throwing")
        } catch {
            outcome.set("\(error)")
        }
    }
    try #require(finished, "a stalled download was never stopped")
    #expect(outcome.value.contains("no progress"), "the error should name the stall, got: \(outcome.value)")
}

@Test("A helper that never reports a download still gets only the flat warm-up limit (F522)")
func warmDictationEngineSilentHelperKeepsTheFlatLimit() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("WarmEngineSilentFlat-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let release = tmp.appendingPathComponent("release")
    defer { try? Data().write(to: release) }
    let script = tmp.appendingPathComponent("silent.sh")
    let helper = """
    while [ -d "\(tmp.path)" ] && [ ! -e "\(release.path)" ]; do sleep 0.05; done
    """
    try helper.write(to: script, atomically: true, encoding: .utf8)

    let engine = WarmWhisperDictationEngine(
        python: URL(fileURLWithPath: "/bin/sh"),
        script: script,
        modelDirectory: tmp
    )
    defer { engine.shutdown() }
    engine.warmUpTimeout = 1
    engine.downloadStallTimeout = 600 // a silent helper never enters stall mode, so this is unreachable

    let outcome = ThrownMessage()
    let finished = try await finishesWithinCap {
        do {
            try await engine.warmUp()
            outcome.set("")
        } catch {
            outcome.set("\(error)")
        }
    }
    try #require(finished, "a silent helper outlived the flat warm-up limit")
    #expect(!outcome.value.isEmpty, "the flat limit should have ended the wait with an error")
}
