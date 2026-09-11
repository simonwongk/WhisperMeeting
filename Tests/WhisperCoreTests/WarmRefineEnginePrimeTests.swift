import Darwin
import Foundation
import Testing
@testable import WhisperCore

/// Reads a pid a test helper wrote, or nil while the file exists but is still empty — the helper
/// creates the file before its write lands, so existence alone does not mean readable.
private func recordedRefinePID(_ url: URL) -> Int32? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
}

private final class RefineEvictionCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func markFinished() {
        lock.withLock { finished = true }
    }

    var isFinished: Bool {
        lock.withLock { finished }
    }
}

/// F203 — `warmUp()` primes the resident refine server exactly once per process with the real
/// base system prompt, and reads the prime's reply inside warmUp (a half-consumed prime would
/// desync every later request on the newline-JSON wire). Driven against a fake Python line-server
/// that numbers its replies, so the assertions also prove the stream stays in sync.

private let fakeServer = """
import sys, json
print(json.dumps({"ready": True}), flush=True)
n = 0
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    n += 1
    req = json.loads(line)
    print(json.dumps({"text": f"{n}:{req['text']}"}), flush=True)
"""

private func makeFixture() throws -> (engine: WarmRefineEngine, root: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WarmRefineEnginePrimeTests-\(UUID().uuidString)")
    let modelDir = root.appendingPathComponent("model", isDirectory: true)
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
    let script = root.appendingPathComponent("fake_refine_server.py")
    try Data(fakeServer.utf8).write(to: script)
    FileManager.default.createFile(
        atPath: modelDir.appendingPathComponent("model.safetensors").path, contents: Data())
    let engine = WarmRefineEngine(
        python: URL(fileURLWithPath: "/usr/bin/python3"),
        script: script,
        modelDirectory: modelDir,
        primePrompt: "PRIME"
    )
    return (engine, root)
}

@Test("warmUp primes once, consumes the prime reply, and later requests stay in sync")
func warmUpPrimesOnceAndStaysInSync() async throws {
    let (engine, root) = try makeFixture()
    defer {
        engine.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
    try await engine.warmUp()
    try await engine.warmUp() // second warmUp must NOT send a second prime
    let reply = try await engine.refine(
        RefineRequest(text: "hello", systemPrompt: "SYS", maxTokens: 8))
    #expect(reply == "2:hello") // prime was request 1; a desync or re-prime would break this
}

@Test("A prime-less engine sends nothing at warmUp")
func noPrimePromptSendsNothing() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WarmRefineEnginePrimeTests-none-\(UUID().uuidString)")
    let modelDir = root.appendingPathComponent("model", isDirectory: true)
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
    let script = root.appendingPathComponent("fake_refine_server.py")
    try Data(fakeServer.utf8).write(to: script)
    FileManager.default.createFile(
        atPath: modelDir.appendingPathComponent("model.safetensors").path, contents: Data())
    let engine = WarmRefineEngine(
        python: URL(fileURLWithPath: "/usr/bin/python3"),
        script: script,
        modelDirectory: modelDir
    )
    defer {
        engine.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
    try await engine.warmUp()
    let reply = try await engine.refine(
        RefineRequest(text: "hello", systemPrompt: "SYS", maxTokens: 8))
    #expect(reply == "1:hello")
}

@Test("evict releases the refine helper and a later warm-up starts a fresh, primed process (F206)")
func evictThenRewarmRestartsRefineHelper() async throws {
    let (engine, root) = try makeFixture()
    defer {
        engine.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    try await engine.warmUp()
    await engine.evict()
    try await engine.warmUp()
    let reply = try await engine.refine(
        RefineRequest(text: "hello", systemPrompt: "SYS", maxTokens: 8))

    // A fresh fake server numbers the re-prime as request 1 and the real request as 2.
    #expect(reply == "2:hello")
}

@Test("refiner eviction force-stops a TERM-ignoring helper while its read is blocked (F206)")
func warmRefineEngineEvictionForceStopsWedgedHelper() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WarmRefineEngineForceEvict-\(UUID().uuidString)")
    let modelDir = root.appendingPathComponent("model", isDirectory: true)
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    FileManager.default.createFile(
        atPath: modelDir.appendingPathComponent("model.safetensors").path, contents: Data())

    let pidFile = root.appendingPathComponent("helper.pid")
    let childPIDFile = root.appendingPathComponent("helper-child.pid")
    let script = root.appendingPathComponent("ignore_term.py")
    let helper = """
    import os, signal, subprocess, sys, time
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    with open(\(String(reflecting: pidFile.path)), "w") as file:
        file.write(str(os.getpid()))
    child = subprocess.Popen([
        sys.executable, "-c",
        "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN);\\nwhile True: time.sleep(1)",
    ])
    with open(\(String(reflecting: childPIDFile.path)), "w") as file:
        file.write(str(child.pid))
    while True:
        time.sleep(1)
    """
    try helper.write(to: script, atomically: true, encoding: .utf8)
    let engine = WarmRefineEngine(
        python: URL(fileURLWithPath: "/usr/bin/python3"),
        script: script,
        modelDirectory: modelDir
    )
    defer { engine.shutdown() }
    let warm = Task { try await engine.warmUp() }
    // Wait for a readable pid, not merely for the file: `open(..., "w")` creates it empty before
    // the write flushes, and a cleanup with no pid to signal leaves a TERM-ignoring descendant
    // holding this suite's read open forever.
    for _ in 0..<200 where recordedRefinePID(pidFile) == nil
        || recordedRefinePID(childPIDFile) == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(recordedRefinePID(pidFile) != nil)
    #expect(recordedRefinePID(childPIDFile) != nil)

    let completion = RefineEvictionCompletion()
    let eviction = Task {
        await engine.evict()
        completion.markFinished()
    }

    for _ in 0..<140 where !completion.isFinished {
        try await Task.sleep(for: .milliseconds(50))
    }
    let finishedWithoutManualKill = completion.isFinished
    // Signal every recorded pid directly rather than the process group: production's escalation
    // may already have reaped the group leader, and `getpgid` on a dead leader cannot name the
    // surviving tree. Missing the descendant here parks the suite on a read that never ends.
    if !finishedWithoutManualKill {
        for pidRecord in [pidFile, childPIDFile] {
            guard let pid = recordedRefinePID(pidRecord) else { continue }
            _ = Darwin.kill(pid, SIGKILL)
        }
    }
    #expect(finishedWithoutManualKill)
    await eviction.value
    _ = await warm.result
}
