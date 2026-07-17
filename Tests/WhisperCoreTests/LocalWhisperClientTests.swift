import Foundation
import Testing
@testable import WhisperCore

@Test("Local Whisper preserves the original language and uses accuracy settings")
func transcribesWithLocalWhisper() async throws {
    let fixture = try LocalWhisperFixture()
    defer { fixture.remove() }

    let client = LocalWhisperClient(
        executableURL: fixture.executableURL,
        modelDirectory: fixture.modelDirectory
    )
    let result = try await client.transcribe(
        recordingAt: fixture.audioURL,
        options: .accuracyFirst(
            model: .large,
            language: .chinese,
            keyterms: ["WhisperMeet", "客户成功"]
        )
    )

    #expect(result.text == "你好，欢迎使用 WhisperMeet。")
    #expect(result.languageCode == "zh")
    #expect(result.segments == [
        TranscriptSegment(
            speaker: nil,
            start: 0.25,
            end: 2.5,
            text: "你好，欢迎使用 WhisperMeet。"
        )
    ])

    let arguments = try String(contentsOf: fixture.argumentsURL, encoding: .utf8)
        .split(separator: "\n")
        .map(String.init)
    #expect(arguments.containsSubsequence(["--model", "large"]))
    #expect(arguments.containsSubsequence(["--model_dir", fixture.modelDirectory.path]))
    #expect(arguments.containsSubsequence(["--task", "transcribe"]))
    #expect(arguments.containsSubsequence(["--language", "Chinese"]))
    #expect(arguments.containsSubsequence(["--initial_prompt", "WhisperMeet, 客户成功"]))
    #expect(arguments.containsSubsequence(["--carry_initial_prompt", "True"]))
    #expect(arguments.containsSubsequence(["--output_format", "json"]))
}

@Test("Automatic detection does not force a language and Turbo remains original-language transcription")
func usesAutomaticLanguageWithTurbo() async throws {
    let fixture = try LocalWhisperFixture()
    defer { fixture.remove() }
    let client = LocalWhisperClient(
        executableURL: fixture.executableURL,
        modelDirectory: fixture.modelDirectory
    )

    _ = try await client.transcribe(
        recordingAt: fixture.audioURL,
        options: .accuracyFirst(model: .turbo, language: .automatic)
    )

    let arguments = try String(contentsOf: fixture.argumentsURL, encoding: .utf8)
        .split(separator: "\n")
        .map(String.init)
    #expect(arguments.containsSubsequence(["--model", "turbo"]))
    #expect(arguments.containsSubsequence(["--task", "transcribe"]))
    #expect(!arguments.contains("--language"))
    #expect(!arguments.contains("--initial_prompt"))
}

@Test("A missing local runtime gives an actionable error")
func reportsMissingRuntime() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetTests-\(UUID().uuidString)", isDirectory: true)
    let audioURL = directory.appendingPathComponent("meeting.wav")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: audioURL)
    defer { try? FileManager.default.removeItem(at: directory) }
    let client = LocalWhisperClient(
        executableURL: directory.appendingPathComponent("missing-whisper"),
        modelDirectory: directory.appendingPathComponent("Models")
    )

    await #expect(throws: LocalWhisperError.runtimeNotInstalled) {
        try await client.transcribe(recordingAt: audioURL)
    }
}

@Test("Local Whisper process failures include the useful diagnostic")
func reportsProcessFailure() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetTests-\(UUID().uuidString)", isDirectory: true)
    let executableURL = directory.appendingPathComponent("whisper")
    let audioURL = directory.appendingPathComponent("meeting.wav")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: audioURL)
    try makeExecutable(
        at: executableURL,
        script: "#!/bin/zsh\nprint -u2 'model could not load'\nexit 7\n"
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let client = LocalWhisperClient(
        executableURL: executableURL,
        modelDirectory: directory.appendingPathComponent("Models")
    )

    await #expect(throws: LocalWhisperError.processFailed("model could not load")) {
        try await client.transcribe(recordingAt: audioURL)
    }
}

@Test("Cancelling transcription terminates the local Whisper process")
func cancelsLocalProcess() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetTests-\(UUID().uuidString)", isDirectory: true)
    let executableURL = directory.appendingPathComponent("whisper")
    let audioURL = directory.appendingPathComponent("meeting.wav")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: audioURL)
    try makeExecutable(
        at: executableURL,
        script: "#!/bin/zsh\nwhile true; do :; done\n"
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let client = LocalWhisperClient(
        executableURL: executableURL,
        modelDirectory: directory.appendingPathComponent("Models")
    )
    let task = Task {
        try await client.transcribe(recordingAt: audioURL)
    }

    try await Task.sleep(for: .milliseconds(150))
    task.cancel()

    await #expect(throws: CancellationError.self) {
        try await task.value
    }
}

private struct LocalWhisperFixture {
    let directory: URL
    let executableURL: URL
    let audioURL: URL
    let modelDirectory: URL
    let argumentsURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperMeetTests-\(UUID().uuidString)", isDirectory: true)
        executableURL = directory.appendingPathComponent("whisper")
        audioURL = directory.appendingPathComponent("meeting.wav")
        modelDirectory = directory.appendingPathComponent("Models", isDirectory: true)
        argumentsURL = audioURL.appendingPathExtension("arguments")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: audioURL)

        let script = #"""
        #!/bin/zsh
        set -euo pipefail
        audio="$1"
        shift
        printf '%s\n' "$@" > "${audio}.arguments"
        output_dir=""
        while (( $# > 0 )); do
          if [[ "$1" == "--output_dir" ]]; then
            output_dir="$2"
            break
          fi
          shift
        done
        mkdir -p "$output_dir"
        printf '%s' '{"text":"你好，欢迎使用 WhisperMeet。","language":"zh","segments":[{"start":0.25,"end":2.5,"text":"你好，欢迎使用 WhisperMeet。"}]}' > "$output_dir/meeting.json"
        """#
        try makeExecutable(at: executableURL, script: script)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func makeExecutable(at url: URL, script: String) throws {
    try Data(script.utf8).write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: url.path
    )
}

private extension Array where Element: Equatable {
    func containsSubsequence(_ subsequence: [Element]) -> Bool {
        guard !subsequence.isEmpty, subsequence.count <= count else { return false }
        return indices.dropLast(subsequence.count - 1).contains { start in
            Array(self[start..<(start + subsequence.count)]) == subsequence
        }
    }
}
