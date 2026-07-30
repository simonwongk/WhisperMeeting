import Foundation
import Testing
@testable import WhisperCore

/// Belt-and-braces for the same failure class: even if a helper (or a future version of a helper's
/// dependencies) writes chatter to stdout, one stray line must not be mistaken for a reply. Without
/// this, the stream desyncs permanently — every response answers the *previous* request.
@Test("Helper chatter on stdout is skipped instead of being read as a protocol message")
func warmDictationEngineSkipsStdoutChatter() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("WarmEngineChatter-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let script = tmp.appendingPathComponent("chatty.sh")
    try """
    echo "Detected language: English"
    echo '{"ready": true}'
    while IFS= read -r line; do
      echo "Detected language: English"
      echo '{"text": "chatter tolerated", "language": "en", "noSpeechProb": 0.01}'
    done
    """.write(to: script, atomically: true, encoding: .utf8)

    let engine = WarmWhisperDictationEngine(
        python: URL(fileURLWithPath: "/bin/sh"),
        script: script,
        modelDirectory: tmp
    )
    defer { engine.shutdown() }

    try await engine.warmUp() // would throw "Dictation helper failed to start." on the chatter line
    let result = try await engine.transcribe(
        wavAt: tmp.appendingPathComponent("clip.wav"),
        language: .automatic,
        initialPrompt: nil
    )
    #expect(result.text == "chatter tolerated")
    #expect(result.languageCode == "en")
}

/// `whisper_dictate_server.py` speaks newline-delimited JSON on stdout, so ANY other stdout write
/// desynchronises the protocol by a line. mlx_whisper/openai-whisper print "Detected language: …"
/// whenever `verbose is not None` — and `verbose=False` is not None. Auto-detect is the app's
/// default language, so this fires on warm-up AND on every automatic request.
@Test("Whisper dictation helper keeps stdout pure JSON when the model auto-detects language")
func whisperDictationHelperStdoutIsPureJSON() throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let helper = repository.appendingPathComponent("Scripts/whisper_dictate_server.py")

    let sandbox = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperHelperStdout-\(UUID().uuidString)", isDirectory: true)
    let fakes = sandbox.appendingPathComponent("fakes/mlx", isDirectory: true)
    try FileManager.default.createDirectory(at: fakes, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: sandbox) }

    try "".write(to: fakes.appendingPathComponent("__init__.py"), atomically: true, encoding: .utf8)
    try """
    float32 = "float32"
    def zeros(count, dtype=None):
        return [0.0] * count
    """.write(to: fakes.appendingPathComponent("core.py"), atomically: true, encoding: .utf8)

    // Reproduces the real library's contract exactly: it announces the detected language on stdout
    // unless `verbose` is None (openai/whisper transcribe.py, mirrored by mlx_whisper).
    try """
    def transcribe(audio, path_or_hf_repo=None, task=None, language=None,
                   initial_prompt=None, verbose=False):
        if language is None and verbose is not None:
            print("Detected language: English")
        return {"text": " hello ", "language": "en",
                "segments": [{"no_speech_prob": 0.01}]}
    """.write(
        to: sandbox.appendingPathComponent("fakes/mlx_whisper.py"),
        atomically: true,
        encoding: .utf8
    )

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
        helper.path,
        "--model-dir", sandbox.appendingPathComponent("models").path,
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["PYTHONPATH"] = sandbox.appendingPathComponent("fakes").path
    environment["PYTHONUNBUFFERED"] = "1"
    process.environment = environment

    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    try process.run()

    // `language: null` is the app's "Detect automatically" default — the auto-detect path.
    let request = #"{"wavPath": "/tmp/clip.wav", "language": null, "initialPrompt": null}"#
    input.fileHandleForWriting.write(Data((request + "\n").utf8))
    try input.fileHandleForWriting.close()

    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let stderrText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let lines = String(decoding: data, as: UTF8.self)
        .split(separator: "\n", omittingEmptySubsequences: true)
    let diagnostic = Comment(rawValue: "stdout:\n\(String(decoding: data, as: UTF8.self))\nstderr:\n\(stderrText)")

    #expect(!lines.isEmpty, diagnostic)
    for line in lines {
        #expect(
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil,
            Comment(rawValue: "non-JSON line on the wire: \(line)")
        )
    }
    #expect(lines.first.map { $0.contains("\"ready\"") } == true, diagnostic)
    #expect(lines.count == 2, diagnostic) // exactly: ready + one response
    #expect(lines.last?.contains("\"text\": \"hello\"") == true, diagnostic)
}
