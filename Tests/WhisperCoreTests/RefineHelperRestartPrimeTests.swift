import Darwin
import Foundation
import Testing
@testable import WhisperCore

// F853 — a refine helper that died between dictations is restarted by the next `refine()`
// (`ensureRunning`), and that dictation's own prompt became the fresh helper's first request: the
// prime that `warmUp()` sends to every new child (F203) was skipped, so the anchor F630 builds was
// that dictation's rather than the prime's, and a near-tie could come out differently from a primed
// helper's for that one dictation. A restarted helper now primes before it serves.

@Test("A refine helper restarted by refine() is primed before it serves the dictation (F853)")
func aRestartedRefineHelperIsPrimedFirst() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("F853-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    try Data("weights".utf8).write(to: tmp.appendingPathComponent("model.safetensors"))
    let requests = tmp.appendingPathComponent("requests.log")
    let pidFile = tmp.appendingPathComponent("helper.pid")
    // Records each request it is sent and answers it, as `refine_server.py` frames its replies.
    let script = tmp.appendingPathComponent("helper.sh")
    try """
    echo $$ > '\(pidFile.path)'
    printf '{"ready":true}\\n'
    while IFS= read -r request; do
      printf '%s\\n' "$request" >> '\(requests.path)'
      printf '{"text":"ok"}\\n'
    done
    """.write(to: script, atomically: true, encoding: .utf8)

    let prime = "PRIME SYSTEM PROMPT"
    let engine = WarmRefineEngine(
        python: URL(fileURLWithPath: "/bin/sh"), script: script, modelDirectory: tmp, primePrompt: prime
    )
    defer { engine.shutdown() }
    try await engine.warmUp()

    // The helper dies between dictations.
    let pid = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    try FileManager.default.removeItem(at: pidFile)
    #expect(kill(pid, SIGKILL) == 0)
    let deadline = ContinuousClock.now + .seconds(30)
    while kill(pid, 0) == 0, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(kill(pid, 0) != 0, "the killed helper was never reaped")

    _ = try await engine.refine(RefineRequest(text: "hello", systemPrompt: "DICTATION PROMPT", maxTokens: 64))

    let sent = try String(contentsOf: requests, encoding: .utf8)
        .split(separator: "\n")
        .map { try JSONDecoder().decode(RefineRequest.self, from: Data($0.utf8)) }
    #expect(sent.map(\.systemPrompt) == [prime, prime, "DICTATION PROMPT"],
            "requests in order: \(sent.map(\.systemPrompt))")
    #expect(sent.last?.text == "hello")
}
