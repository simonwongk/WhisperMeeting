import Foundation
import Testing
@testable import WhisperCore

// F756 — `refine_server.py` now answers a damaged Summaries model with one `error` line naming the
// folder (Scripts/tests/test_refine_server.py pins that line; the installed runtime produced it on
// 2026-10-16 for a missing config.json and a corrupt model.safetensors). This is the Swift half:
// the warm-up reports that sentence as the helper's failure, not "Refine helper stopped
// unexpectedly." with a traceback.

@Test("A refine helper that says its model cannot be read fails warm-up with its own sentence (F756)")
func aDamagedRefineModelFailsWarmUpWithTheHelpersSentence() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("F756-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    // A weights file is there — the app checks only that it exists before it starts the helper —
    // and it is not safetensors, the corrupt-install case.
    try Data("garbage-not-safetensors".utf8).write(to: tmp.appendingPathComponent("model.safetensors"))
    let sentence = "The on-device model in /models/damaged could not be read (RuntimeError: [load_safetensors] Invalid json header length). Its files may be incomplete or damaged. Use Repair or Update under Summaries in Settings, then try again."
    let script = tmp.appendingPathComponent("damaged.sh")
    try """
    printf '%s\\n' '{"error": "\(sentence)"}'
    exit 1
    """.write(to: script, atomically: true, encoding: .utf8)

    let engine = WarmRefineEngine(
        python: URL(fileURLWithPath: "/bin/sh"), script: script, modelDirectory: tmp
    )
    defer { engine.shutdown() }
    do {
        try await engine.warmUp()
        Issue.record("warm-up succeeded over a helper that reported a damaged model")
    } catch let error as SummarizerError {
        #expect(error == .helperFailed(sentence))
    }
}
