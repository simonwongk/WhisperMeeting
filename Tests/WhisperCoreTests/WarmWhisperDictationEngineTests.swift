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
