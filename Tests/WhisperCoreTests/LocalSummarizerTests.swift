import Foundation
import Testing
@testable import WhisperCore

/// F164 — the on-device summarizer. Exercised with a fake "python" that writes a canned --output
/// payload, mirroring QwenASRClientTests, so the spawn/parse/cancel contract is tested without a
/// real model.

@Test("Local summarizer runs the helper and decodes its payload into a MeetingSummary")
func localSummarizerDecodesPayload() async throws {
    let fixture = try LocalSummaryFixture()
    defer { fixture.remove() }
    let summarizer = LocalSummarizer(
        pythonExecutableURL: fixture.pythonURL,
        helperScriptURL: fixture.helperURL,
        modelDirectory: fixture.modelDirectory
    )

    let result = try await summarizer.summarize(
        transcript: "Alice and Bob planned the launch.",
        language: "en",
        style: .balanced
    )

    #expect(result.summary == "We shipped v1.")
    #expect(result.keyPoints == ["Ship v1", "Hire QA"])
    #expect(result.actionItems == ["Email vendor"])

    let arguments = try String(contentsOf: fixture.argumentsURL, encoding: .utf8)
        .split(separator: "\n").map(String.init)
    #expect(arguments.containsSubsequence(["--model", fixture.modelDirectory.path]))
    #expect(arguments.containsSubsequence(["--max-tokens", "2048"]))
    // The client owns the --input/--output paths (temp files in its own working directory); that they
    // round-trip is proven by the decoded result above. Here we just confirm the flags are present.
    #expect(arguments.contains("--output"))
    #expect(arguments.contains("--input"))

    // The request forwards the shared system prompt (do-not-translate clause) plus the local
    // JSON-format directive and the transcript verbatim.
    let request = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.inputCaptureURL))
            as? [String: String]
    )
    #expect(request["transcript"] == "Alice and Bob planned the launch.")
    let system = try #require(request["systemPrompt"])
    #expect(system.contains("Do not translate"))
    #expect(system.contains("JSON object with exactly these keys"))

    // The model runs fully offline.
    #expect(try String(contentsOf: fixture.environmentURL, encoding: .utf8) == "1,1")
}

@Test("Local summarizer refuses an empty transcript before spawning anything")
func localSummarizerRejectsEmptyTranscript() async throws {
    let fixture = try LocalSummaryFixture()
    defer { fixture.remove() }
    let summarizer = LocalSummarizer(
        pythonExecutableURL: fixture.pythonURL,
        helperScriptURL: fixture.helperURL,
        modelDirectory: fixture.modelDirectory
    )
    await #expect(throws: SummarizerError.emptyTranscript) {
        _ = try await summarizer.summarize(transcript: "   ", language: nil, style: .balanced)
    }
}

@Test("Local summarizer reports modelNotInstalled when the model is missing")
func localSummarizerRejectsMissingModel() async throws {
    let fixture = try LocalSummaryFixture()
    defer { fixture.remove() }
    try FileManager.default.removeItem(
        at: fixture.modelDirectory.appendingPathComponent("model.safetensors")
    )
    let summarizer = LocalSummarizer(
        pythonExecutableURL: fixture.pythonURL,
        helperScriptURL: fixture.helperURL,
        modelDirectory: fixture.modelDirectory
    )
    await #expect(throws: SummarizerError.modelNotInstalled) {
        _ = try await summarizer.summarize(transcript: "hello", language: nil, style: .balanced)
    }
}

@Test("Local summarizer still returns a degraded raw-text summary rather than failing")
func localSummarizerReturnsDegradedSummary() async throws {
    let fixture = try LocalSummaryFixture(outputJSON: """
    {"summary":"A recap the model wrote as prose.","keyPoints":[],"actionItems":[],\
    "warning":"The local model did not return JSON; used its text as the summary.",\
    "finishReason":"stop","generatedTokens":12}
    """)
    defer { fixture.remove() }
    let summarizer = LocalSummarizer(
        pythonExecutableURL: fixture.pythonURL,
        helperScriptURL: fixture.helperURL,
        modelDirectory: fixture.modelDirectory
    )
    let result = try await summarizer.summarize(transcript: "hello", language: nil, style: .brief)
    #expect(result.summary == "A recap the model wrote as prose.")
    #expect(result.keyPoints.isEmpty)
}

@Test("Local summarizer surfaces a helper failure as helperFailed")
func localSummarizerSurfacesHelperFailure() async throws {
    let fixture = try LocalSummaryFixture(script: "#!/bin/zsh\nprint -u2 'model load blew up'\nexit 1\n")
    defer { fixture.remove() }
    let summarizer = LocalSummarizer(
        pythonExecutableURL: fixture.pythonURL,
        helperScriptURL: fixture.helperURL,
        modelDirectory: fixture.modelDirectory
    )
    do {
        _ = try await summarizer.summarize(transcript: "hello", language: nil, style: .balanced)
        Issue.record("expected a helperFailed throw")
    } catch let error as SummarizerError {
        guard case let .helperFailed(message) = error else {
            Issue.record("expected helperFailed, got \(error)")
            return
        }
        #expect(message.contains("model load blew up"))
    }
}

@Test("Cancelling a local summary terminates its helper process")
func localSummarizerCancellation() async throws {
    let fixture = try LocalSummaryFixture(script: "#!/bin/zsh\nexec sleep 120\n")
    defer { fixture.remove() }
    let summarizer = LocalSummarizer(
        pythonExecutableURL: fixture.pythonURL,
        helperScriptURL: fixture.helperURL,
        modelDirectory: fixture.modelDirectory
    )
    let task = Task {
        try await summarizer.summarize(transcript: "hello", language: nil, style: .balanced)
    }
    try await Task.sleep(for: .milliseconds(150))
    task.cancel()
    await #expect(throws: CancellationError.self) {
        try await task.value
    }
}

@Test("Summarizer model choice follows physical RAM: 8B at/above 16 GiB, 4B below")
func summarizerModelPickByRAM() {
    let gib: UInt64 = 1024 * 1024 * 1024
    #expect(SummarizerRuntime.recommendedRepository(physicalMemory: 8 * gib) == SummarizerRuntime.fallbackRepository)
    #expect(SummarizerRuntime.recommendedRepository(physicalMemory: 15 * gib) == SummarizerRuntime.fallbackRepository)
    #expect(SummarizerRuntime.recommendedRepository(physicalMemory: 16 * gib) == SummarizerRuntime.defaultRepository)
    #expect(SummarizerRuntime.recommendedRepository(physicalMemory: 18 * gib) == SummarizerRuntime.defaultRepository)
}

@Test("Summarizer runtime is ready only when interpreter, helper, and model all exist")
func summarizerRuntimeCompleteness() throws {
    let support = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetSummarizerRuntimeTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: support) }
    try FileManager.default.createDirectory(
        at: SummarizerRuntime.managedDirectory(applicationSupport: support).appendingPathComponent("venv/bin"),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: SummarizerRuntime.modelDirectory(applicationSupport: support),
        withIntermediateDirectories: true
    )
    let python = SummarizerRuntime.pythonExecutable(applicationSupport: support)
    try Data("#!/bin/zsh\n".utf8).write(to: python)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)

    #expect(!SummarizerRuntime.isInstalled(applicationSupport: support))
    try Data("helper".utf8).write(to: SummarizerRuntime.helperScript(applicationSupport: support))
    #expect(!SummarizerRuntime.isInstalled(applicationSupport: support))
    try Data("weights".utf8).write(
        to: SummarizerRuntime.modelDirectory(applicationSupport: support)
            .appendingPathComponent("model.safetensors")
    )
    #expect(SummarizerRuntime.isInstalled(applicationSupport: support))
}

private struct LocalSummaryFixture {
    let directory: URL
    let pythonURL: URL
    let helperURL: URL
    let modelDirectory: URL
    let argumentsURL: URL
    let environmentURL: URL
    let inputCaptureURL: URL

    init(script customScript: String? = nil, outputJSON: String? = nil) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperMeetSummaryTests-\(UUID().uuidString)", isDirectory: true)
        pythonURL = directory.appendingPathComponent("python")
        helperURL = directory.appendingPathComponent("summarize_local.py")
        modelDirectory = directory.appendingPathComponent("model", isDirectory: true)
        argumentsURL = directory.appendingPathComponent("arguments.txt")
        environmentURL = directory.appendingPathComponent("environment.txt")
        inputCaptureURL = directory.appendingPathComponent("input-capture.json")

        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try Data("helper".utf8).write(to: helperURL)
        try Data("weights".utf8).write(to: modelDirectory.appendingPathComponent("model.safetensors"))

        let payload = outputJSON ?? """
        {"summary":"We shipped v1.","keyPoints":["Ship v1","Hire QA"],"actionItems":["Email vendor"],\
        "warning":null,"finishReason":"stop","generatedTokens":42}
        """
        // The default fake python records args/env, captures the --input request, and writes a canned
        // payload to whatever --output path the client chose (a temp file in its working directory).
        let defaultScript = """
        #!/bin/zsh
        set -euo pipefail
        printf '%s\\n' "$@" > '\(argumentsURL.path)'
        printf '%s,%s' "${HF_HUB_OFFLINE:-}" "${TRANSFORMERS_OFFLINE:-}" > '\(environmentURL.path)'
        input=""
        output=""
        while (( $# > 0 )); do
          if [[ "$1" == "--input" ]]; then input="$2"; fi
          if [[ "$1" == "--output" ]]; then output="$2"; fi
          shift
        done
        [[ -n "$input" ]] && cp "$input" '\(inputCaptureURL.path)'
        printf '%s' '\(payload)' > "$output"
        """
        let script = customScript ?? defaultScript
        try script.write(to: pythonURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pythonURL.path)
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
