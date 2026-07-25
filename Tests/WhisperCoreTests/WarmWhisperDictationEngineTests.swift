import Testing
import Foundation
@testable import WhisperCore

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
