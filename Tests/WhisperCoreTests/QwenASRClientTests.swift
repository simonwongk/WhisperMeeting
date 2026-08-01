import Foundation
import Testing
@testable import WhisperCore

@Test("Qwen client keeps punctuated text and converts word alignment into timestamped sentences")
func qwenClientTranscribesWithAlignment() async throws {
    let fixture = try QwenClientFixture()
    defer { fixture.remove() }
    let client = QwenASRClient(
        pythonExecutableURL: fixture.pythonURL,
        helperScriptURL: fixture.helperURL,
        modelDirectory: fixture.modelDirectory,
        alignerDirectory: fixture.alignerDirectory
    )

    let result = try await client.transcribe(
        recordingAt: fixture.audioURL,
        language: .automatic
    )

    #expect(result.text == "会议 ready. Send it!")
    #expect(result.languageCode == nil)
    #expect(result.segments == [
        TranscriptSegment(speaker: nil, start: 0.0, end: 0.8, text: "会议 ready."),
        TranscriptSegment(speaker: nil, start: 1.0, end: 1.6, text: "Send it!"),
    ])

    let arguments = try String(contentsOf: fixture.argumentsURL, encoding: .utf8)
        .split(separator: "\n")
        .map(String.init)
    #expect(arguments.containsSubsequence(["--model", fixture.modelDirectory.path]))
    #expect(arguments.containsSubsequence(["--aligner", fixture.alignerDirectory.path]))
    #expect(arguments.containsSubsequence(["--audio", fixture.audioURL.path]))
    #expect(arguments.containsSubsequence(["--language", "auto"]))
    let environment = try String(contentsOf: fixture.environmentURL, encoding: .utf8)
    #expect(environment == "1,1")
}

@Test("Qwen client refuses an incomplete runtime before reading the recording")
func qwenClientRejectsIncompleteRuntime() async throws {
    let fixture = try QwenClientFixture()
    defer { fixture.remove() }
    try FileManager.default.removeItem(
        at: fixture.alignerDirectory.appendingPathComponent("model.safetensors")
    )
    let client = QwenASRClient(
        pythonExecutableURL: fixture.pythonURL,
        helperScriptURL: fixture.helperURL,
        modelDirectory: fixture.modelDirectory,
        alignerDirectory: fixture.alignerDirectory
    )

    await #expect(throws: QwenASRError.runtimeNotInstalled) {
        try await client.transcribe(recordingAt: fixture.audioURL)
    }
}

@Test("Qwen client preserves complete text when the helper reports alignment failure")
func qwenClientKeepsTextWithoutAlignment() async throws {
    let fixture = try QwenClientFixture(outputJSON: """
    {"text":"Keep every recognized word.","language":"en","alignedItems":[],"alignmentWarning":"RuntimeError: aligner failed"}
    """)
    defer { fixture.remove() }
    let client = QwenASRClient(
        pythonExecutableURL: fixture.pythonURL,
        helperScriptURL: fixture.helperURL,
        modelDirectory: fixture.modelDirectory,
        alignerDirectory: fixture.alignerDirectory
    )

    let result = try await client.transcribe(recordingAt: fixture.audioURL)

    #expect(result.text == "Keep every recognized word.")
    #expect(result.segments.isEmpty)
}

@Test("Qwen runtime is ready only when the interpreter, helper, and both models exist")
func qwenRuntimeCompleteness() throws {
    let support = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetQwenRuntimeTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: support) }
    let runtime = QwenASRRuntime.managedDirectory(applicationSupport: support)
    try FileManager.default.createDirectory(
        at: runtime.appendingPathComponent("venv/bin"),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: QwenASRRuntime.modelDirectory(applicationSupport: support),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: QwenASRRuntime.alignerDirectory(applicationSupport: support),
        withIntermediateDirectories: true
    )
    let python = QwenASRRuntime.pythonExecutable(applicationSupport: support)
    try Data("#!/bin/zsh\n".utf8).write(to: python)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: python.path
    )
    try Data("helper".utf8).write(
        to: QwenASRRuntime.helperScript(applicationSupport: support)
    )
    try Data("model".utf8).write(
        to: QwenASRRuntime.modelDirectory(applicationSupport: support)
            .appendingPathComponent("model.safetensors")
    )

    #expect(!QwenASRRuntime.isInstalled(applicationSupport: support))

    try Data("aligner".utf8).write(
        to: QwenASRRuntime.alignerDirectory(applicationSupport: support)
            .appendingPathComponent("model.safetensors")
    )
    #expect(QwenASRRuntime.isInstalled(applicationSupport: support))
}

@Test("Cancelling Qwen transcription terminates its helper process")
func qwenClientCancellation() async throws {
    let fixture = try QwenClientFixture(script: "#!/bin/zsh\nexec sleep 120\n")
    defer { fixture.remove() }
    let client = QwenASRClient(
        pythonExecutableURL: fixture.pythonURL,
        helperScriptURL: fixture.helperURL,
        modelDirectory: fixture.modelDirectory,
        alignerDirectory: fixture.alignerDirectory
    )
    let task = Task {
        try await client.transcribe(recordingAt: fixture.audioURL)
    }

    try await Task.sleep(for: .milliseconds(150))
    task.cancel()

    await #expect(throws: CancellationError.self) {
        try await task.value
    }
}

private struct QwenClientFixture {
    let directory: URL
    let pythonURL: URL
    let helperURL: URL
    let audioURL: URL
    let modelDirectory: URL
    let alignerDirectory: URL
    let argumentsURL: URL
    let environmentURL: URL

    init(script customScript: String? = nil, outputJSON: String? = nil) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperMeetQwenTests-\(UUID().uuidString)", isDirectory: true)
        pythonURL = directory.appendingPathComponent("python")
        helperURL = directory.appendingPathComponent("qwen_transcribe.py")
        audioURL = directory.appendingPathComponent("meeting.wav")
        modelDirectory = directory.appendingPathComponent("model", isDirectory: true)
        alignerDirectory = directory.appendingPathComponent("aligner", isDirectory: true)
        argumentsURL = directory.appendingPathComponent("arguments.txt")
        environmentURL = directory.appendingPathComponent("environment.txt")

        try FileManager.default.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: alignerDirectory,
            withIntermediateDirectories: true
        )
        try Data("audio".utf8).write(to: audioURL)
        try Data("helper".utf8).write(to: helperURL)
        try Data("model".utf8).write(
            to: modelDirectory.appendingPathComponent("model.safetensors")
        )
        try Data("aligner".utf8).write(
            to: alignerDirectory.appendingPathComponent("model.safetensors")
        )

        let payload = outputJSON ?? """
        {"text":"会议 ready. Send it!","language":null,"alignedItems":[{"text":"会议","start":0.0,"end":0.4},{"text":"ready","start":0.4,"end":0.8},{"text":"Send","start":1.0,"end":1.4},{"text":"it","start":1.4,"end":1.6}]}
        """
        let defaultScript = """
        #!/bin/zsh
        set -euo pipefail
        printf '%s\\n' "$@" > '\(argumentsURL.path)'
        printf '%s,%s' "${HF_HUB_OFFLINE:-}" "${TRANSFORMERS_OFFLINE:-}" > '\(environmentURL.path)'
        output=""
        while (( $# > 0 )); do
          if [[ "$1" == "--output" ]]; then
            output="$2"
            break
          fi
          shift
        done
        printf '%s' '\(payload)' > "$output"
        """
        let script = customScript ?? defaultScript
        try script.write(to: pythonURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: pythonURL.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private extension Array where Element: Equatable {
    func containsSubsequence(_ subsequence: [Element]) -> Bool {
        guard !subsequence.isEmpty, subsequence.count <= count else { return false }
        return indices.dropLast(subsequence.count - 1).contains { start in
            Array(self[start..<(start + subsequence.count)]) == subsequence
        }
    }
}
