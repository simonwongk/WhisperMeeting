import Foundation
import Testing
@testable import WhisperCore

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
