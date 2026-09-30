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

// F475 Part 1 — before this fix, a non-JSON or truncated helper payload was stored and shown as a
// clean summary: `summarize_local.py`'s `parse_summary` degrades rather than raises (a raw-text
// summary with a warning, or a `finishReason: "length"` mid-array truncation), and
// `LocalSummarizer.summarize` read only the three content fields, never `warning`/`finishReason`.
@Test("A non-JSON helper payload is refused, not shown as a clean summary (F475)")
func localSummarizerRefusesNonJSONOutput() async throws {
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
    await #expect(throws: SummarizerError.localOutputDegraded(
        "The local model did not return JSON; used its text as the summary."
    )) {
        _ = try await summarizer.summarize(transcript: "hello", language: nil, style: .brief)
    }
}

@Test("A truncated helper payload (finishReason length) is refused, not shown as a clean summary (F475)")
func localSummarizerRefusesTruncatedOutput() async throws {
    let fixture = try LocalSummaryFixture(outputJSON: """
    {"summary":"The team reviewed the Q3 launch plan and agreed to","keyPoints":["Launch moves to Oct 14"],\
    "actionItems":[],"warning":null,"finishReason":"length","generatedTokens":2048}
    """)
    defer { fixture.remove() }
    let summarizer = LocalSummarizer(
        pythonExecutableURL: fixture.pythonURL,
        helperScriptURL: fixture.helperURL,
        modelDirectory: fixture.modelDirectory
    )
    await #expect(throws: SummarizerError.localOutputTruncated) {
        _ = try await summarizer.summarize(transcript: "hello", language: nil, style: .brief)
    }
}

@Test("A clean helper payload (no warning, ordinary stop) is still returned (F475)")
func localSummarizerStillReturnsACleanSummary() async throws {
    // The regression this guards against: refusing everything, including the common case.
    let fixture = try LocalSummaryFixture(outputJSON: """
    {"summary":"We shipped v1.","keyPoints":["Ship v1"],"actionItems":[],\
    "warning":null,"finishReason":"stop","generatedTokens":42}
    """)
    defer { fixture.remove() }
    let summarizer = LocalSummarizer(
        pythonExecutableURL: fixture.pythonURL,
        helperScriptURL: fixture.helperURL,
        modelDirectory: fixture.modelDirectory
    )
    let result = try await summarizer.summarize(transcript: "hello", language: nil, style: .brief)
    #expect(result.summary == "We shipped v1.")
}

// F475 Part 2 — the three local throw sites used to reuse `.unreadableResponse`, whose copy names
// Claude ("Claude returned a summary the app could not read"), even though nothing here reaches
// Claude.
@Test("An undecodable helper output file is reported without naming Claude (F475)")
func localSummarizerRefusesUndecodableOutputWithoutNamingClaude() async throws {
    let fixture = try LocalSummaryFixture(script: """
    #!/bin/zsh
    while (( $# > 0 )); do
      if [[ "$1" == "--output" ]]; then printf 'not json at all' > "$2"; fi
      shift
    done
    """)
    defer { fixture.remove() }
    let summarizer = LocalSummarizer(
        pythonExecutableURL: fixture.pythonURL,
        helperScriptURL: fixture.helperURL,
        modelDirectory: fixture.modelDirectory
    )
    await #expect(throws: SummarizerError.localOutputUnreadable) {
        _ = try await summarizer.summarize(transcript: "hello", language: nil, style: .balanced)
    }
    #expect(!SummarizerError.localOutputUnreadable.localizedDescription.contains("Claude"))
}

// F475 Part 3 — the helper measures the prompt against the model's context window before loading
// it; `finishReason: "too_long"` is how it reports back that it never even tried.
@Test("A too-long transcript is refused with the helper's own measured detail, verbatim (F475)")
func localSummarizerRefusesATranscriptTooLongForContext() async throws {
    // No apostrophe: the fixture below embeds this JSON inside a single-quoted zsh string, and an
    // apostrophe would break that shell quoting — a fixture artifact, not a production constraint
    // (the real payload travels as a JSON file, never through a shell string).
    let detail = "This transcript needs about 66001 tokens, more than the 38400 available in the " +
        "model 40960-token context window with 2528 reserved for the response. Try a shorter " +
        "selection, or use Claude for long meetings."
    let fixture = try LocalSummaryFixture(outputJSON: """
    {"summary":"","keyPoints":[],"actionItems":[],"warning":\(String(reflecting: detail)),\
    "finishReason":"too_long","generatedTokens":0}
    """)
    defer { fixture.remove() }
    let summarizer = LocalSummarizer(
        pythonExecutableURL: fixture.pythonURL,
        helperScriptURL: fixture.helperURL,
        modelDirectory: fixture.modelDirectory
    )
    await #expect(throws: SummarizerError.localInputTooLong(detail)) {
        _ = try await summarizer.summarize(transcript: "hello", language: nil, style: .balanced)
    }
}

// F598 — a partial or damaged model install (a missing or corrupt config.json, tokenizer, or weights
// file) is reported by the helper as `finishReason: "model_unreadable"` instead of a traceback.
@Test("An unreadable model install is refused with the helper's own detail, verbatim, not as degraded output (F598)")
func localSummarizerRefusesAnUnreadableModel() async throws {
    // No apostrophe: the fixture embeds this JSON inside a single-quoted zsh string.
    let detail = "The on-device model in /tmp/model could not be read (FileNotFoundError: no " +
        "config.json). Its files may be incomplete or damaged. Use Repair or Update under " +
        "Summaries in Settings, then try again."
    let fixture = try LocalSummaryFixture(outputJSON: """
    {"summary":"","keyPoints":[],"actionItems":[],"warning":\(String(reflecting: detail)),\
    "finishReason":"model_unreadable","generatedTokens":0}
    """)
    defer { fixture.remove() }
    let summarizer = LocalSummarizer(
        pythonExecutableURL: fixture.pythonURL,
        helperScriptURL: fixture.helperURL,
        modelDirectory: fixture.modelDirectory
    )
    await #expect(throws: SummarizerError.localModelUnreadable(detail)) {
        _ = try await summarizer.summarize(transcript: "hello", language: nil, style: .balanced)
    }
    // The alert is the detail itself: not wrapped in "could not be read cleanly … try again", whose
    // advice cannot help a broken install.
    #expect(SummarizerError.localModelUnreadable(detail).errorDescription == detail)
}

@Test("Ask and correction map an unreadable model the same way summarize does (F598)")
func unreadableModelRefusalIsSharedByEveryLocalPath() {
    let detail = "The on-device model could not be read."
    #expect(LocalSummarizer.localOutputRefusal(warning: detail, finishReason: "model_unreadable")
            == .localModelUnreadable(detail))
    #expect(LocalSummarizer.answerRefusal(warning: detail, finishReason: "model_unreadable")
            == .localModelUnreadable(detail))
    // A payload without a warning still names the way out.
    let fallback = LocalSummarizer.localOutputRefusal(warning: nil, finishReason: "model_unreadable")
    #expect(fallback?.errorDescription?.contains("Repair or Update") == true, "got \(String(describing: fallback))")
    #expect(LocalSummarizer.answerRefusal(warning: nil, finishReason: "model_unreadable") == fallback)
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

// F512 — a wedged helper held the one summary slot, and with it every Summarize and every Ask answer,
// until the app was quit. The runner is a seam, so a stall is reported without sitting one out. The
// contract this pins is the summarizer's: the helper is run with `defaultStallTimeout` of silence
// allowed — the number the doc comment derives from what the helper reports — and the runner's
// stall comes back in the summarizer's own words, not the runner's download wording.
private final class HelperRunRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _stallTimeouts: [TimeInterval] = []
    var stallTimeouts: [TimeInterval] { lock.withLock { _stallTimeouts } }
    func record(_ stallTimeout: TimeInterval) { lock.withLock { _stallTimeouts.append(stallTimeout) } }
}

@Test("A helper the runner reports as stalled is reported as stalled, after the default ten silent minutes (F512)")
func localSummarizerReportsAStalledHelper() async throws {
    let fixture = try LocalSummaryFixture()
    defer { fixture.remove() }
    let asked = HelperRunRecorder()
    let summarizer = LocalSummarizer(
        pythonExecutableURL: fixture.pythonURL,
        helperScriptURL: fixture.helperURL,
        modelDirectory: fixture.modelDirectory,
        runHelper: { _, _, _, stallTimeout in
            asked.record(stallTimeout)
            throw ProcessGroupRunnerError.stalled(stallTimeout)
        }
    )
    do {
        _ = try await summarizer.summarize(transcript: "hello", language: nil, style: .balanced)
        Issue.record("expected a helperStalled throw")
    } catch let error as SummarizerError {
        #expect(error == .helperStalled(LocalSummarizer.defaultStallTimeout), "got \(error)")
        #expect(error.localizedDescription.contains("made no progress for 10 minutes and was stopped"))
    }
    #expect(asked.stallTimeouts == [LocalSummarizer.defaultStallTimeout])
}

// The seam cannot see inside the default runner, so this runs it for real: a child that prints
// nothing, held to one second of silence. Its failing direction does not depend on how fast the
// host is — a silent child is silent on any host, and left alone the script exits 0 with no output
// 20 s later, which is `helperFailed`, not `helperStalled` — so only a watchdog that fires passes it.
@Test("The default runner is a real stall watchdog: a silent helper is stopped and reported as stalled (F512)")
func localSummarizerStopsASilentHelper() async throws {
    let fixture = try LocalSummaryFixture(script: "#!/bin/zsh\nsleep 20\n")
    defer { fixture.remove() }
    let summarizer = LocalSummarizer(
        pythonExecutableURL: fixture.pythonURL,
        helperScriptURL: fixture.helperURL,
        modelDirectory: fixture.modelDirectory,
        stallTimeout: 1
    )
    do {
        _ = try await summarizer.summarize(transcript: "hello", language: nil, style: .balanced)
        Issue.record("expected a helperStalled throw")
    } catch let error as SummarizerError {
        #expect(error == .helperStalled(1), "got \(error)")
        #expect(error.localizedDescription.contains("made no progress for 1 second and was stopped"))
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
