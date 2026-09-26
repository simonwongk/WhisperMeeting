import Foundation
import Testing
@testable import WhisperCore

/// F165 — the on-device transcript-correction pass. Exercised with a fake "python" that writes a
/// canned corrections payload, mirroring LocalSummarizerTests.

@Test("Corrector decodes the helper payload and keeps only corrections whose `from` is in the transcript")
func correctorDecodesAndFiltersPayload() async throws {
    let fixture = try CorrectorFixture(outputJSON: """
    {"corrections":[{"from":"Kew Bernetes","to":"Kubernetes"},{"from":"Post Grease","to":"Postgres"},\
    {"from":"Hallucinated Term","to":"Nope"},{"from":"same","to":"same"}],\
    "warning":null,"finishReason":"stop","generatedTokens":20}
    """)
    defer { fixture.remove() }
    let corrector = LocalTranscriptCorrector(
        pythonExecutableURL: fixture.pythonURL,
        helperScriptURL: fixture.helperURL,
        modelDirectory: fixture.modelDirectory
    )

    let corrections = try await corrector.correct(
        transcript: "Kew Bernetes runs the cluster and Post Grease stores the data.",
        vocabulary: ["Kubernetes", "Postgres"],
        reference: nil
    )

    // "Hallucinated Term" (not in transcript) and same→same are dropped.
    #expect(corrections == [
        TranscriptCorrection(from: "Kew Bernetes", to: "Kubernetes"),
        TranscriptCorrection(from: "Post Grease", to: "Postgres"),
    ])

    // The request forwards the correction system prompt (forbids paraphrase) + vocabulary + reference.
    let request = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.inputCaptureURL)) as? [String: String]
    )
    let system = try #require(request["systemPrompt"])
    #expect(system.contains("Do NOT paraphrase"))
    let content = try #require(request["transcript"])
    #expect(content.contains("Kubernetes"))
    #expect(content.contains("Correct business vocabulary"))
}

@Test("Corrector passes the reference document through to the helper's user content")
func correctorIncludesReference() async throws {
    let fixture = try CorrectorFixture(outputJSON: #"{"corrections":[],"warning":null,"finishReason":"stop","generatedTokens":1}"#)
    defer { fixture.remove() }
    let corrector = LocalTranscriptCorrector(
        pythonExecutableURL: fixture.pythonURL,
        helperScriptURL: fixture.helperURL,
        modelDirectory: fixture.modelDirectory
    )
    _ = try await corrector.correct(transcript: "hello world", vocabulary: [], reference: "Project Aurora spec")
    let request = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.inputCaptureURL)) as? [String: String]
    )
    #expect(try #require(request["transcript"]).contains("Reference document:\nProject Aurora spec"))
}

@Test("Corrector skips the model when there is nothing to correct toward")
func correctorSkipsWithoutGuidance() async throws {
    let fixture = try CorrectorFixture()
    defer { fixture.remove() }
    let corrector = LocalTranscriptCorrector(
        pythonExecutableURL: fixture.pythonURL,
        helperScriptURL: fixture.helperURL,
        modelDirectory: fixture.modelDirectory
    )
    // Empty vocabulary + no reference → no run, no output file written by the fake.
    let corrections = try await corrector.correct(transcript: "hello world", vocabulary: [], reference: nil)
    #expect(corrections.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.argumentsURL.path))
}

@Test("Corrector reports modelNotInstalled when the model is missing")
func correctorRejectsMissingModel() async throws {
    let fixture = try CorrectorFixture()
    defer { fixture.remove() }
    try FileManager.default.removeItem(
        at: fixture.modelDirectory.appendingPathComponent("model.safetensors")
    )
    let corrector = LocalTranscriptCorrector(
        pythonExecutableURL: fixture.pythonURL,
        helperScriptURL: fixture.helperURL,
        modelDirectory: fixture.modelDirectory
    )
    await #expect(throws: SummarizerError.modelNotInstalled) {
        _ = try await corrector.correct(transcript: "hi", vocabulary: ["Kubernetes"], reference: nil)
    }
}

// F475 Part 1 — `correct_local.py`'s `parse_corrections` degrades rather than raises: unparseable
// output becomes `([], warning)`, which read identically to "the model looked and found nothing to
// fix" (this file's own doc comment on `correctorSkipsWithoutGuidance` notwithstanding — that one
// never runs the model at all). Before this fix, `correct` ignored `warning`/`finishReason`
// entirely, so a degraded or truncated run silently proposed zero corrections indistinguishably
// from a genuine clean pass.
@Test("A non-JSON helper payload is refused, not silently treated as zero corrections found (F475)")
func correctorRefusesNonJSONOutput() async throws {
    let fixture = try CorrectorFixture(outputJSON: """
    {"corrections":[],"warning":"The local model did not return the requested JSON; proposing no corrections.",\
    "finishReason":"stop","generatedTokens":30}
    """)
    defer { fixture.remove() }
    let corrector = LocalTranscriptCorrector(
        pythonExecutableURL: fixture.pythonURL,
        helperScriptURL: fixture.helperURL,
        modelDirectory: fixture.modelDirectory
    )
    await #expect(throws: SummarizerError.localOutputDegraded(
        "The local model did not return the requested JSON; proposing no corrections."
    )) {
        _ = try await corrector.correct(transcript: "hi there", vocabulary: ["Kubernetes"], reference: nil)
    }
}

@Test("A truncated helper payload (finishReason length) is refused (F475)")
func correctorRefusesTruncatedOutput() async throws {
    let fixture = try CorrectorFixture(outputJSON: """
    {"corrections":[{"from":"Kew Bernetes","to":"Kubernetes"}],"warning":null,\
    "finishReason":"length","generatedTokens":2048}
    """)
    defer { fixture.remove() }
    let corrector = LocalTranscriptCorrector(
        pythonExecutableURL: fixture.pythonURL,
        helperScriptURL: fixture.helperURL,
        modelDirectory: fixture.modelDirectory
    )
    await #expect(throws: SummarizerError.localOutputTruncated) {
        _ = try await corrector.correct(transcript: "Kew Bernetes runs the cluster.", vocabulary: ["Kubernetes"], reference: nil)
    }
}

@Test("A genuinely clean 'nothing to fix' pass still returns an empty list (F475)")
func correctorStillReturnsAGenuineEmptyResult() async throws {
    // The regression this guards against: refusing every empty result, including the ordinary one.
    let fixture = try CorrectorFixture(outputJSON: #"{"corrections":[],"warning":null,"finishReason":"stop","generatedTokens":3}"#)
    defer { fixture.remove() }
    let corrector = LocalTranscriptCorrector(
        pythonExecutableURL: fixture.pythonURL,
        helperScriptURL: fixture.helperURL,
        modelDirectory: fixture.modelDirectory
    )
    let corrections = try await corrector.correct(transcript: "hi there", vocabulary: ["Kubernetes"], reference: nil)
    #expect(corrections.isEmpty)
}

// F475 Part 2 — the same Claude-named copy `.unreadableResponse` used to leak into this path too.
@Test("An undecodable helper output file is reported without naming Claude (F475)")
func correctorRefusesUndecodableOutputWithoutNamingClaude() async throws {
    let fixture = try CorrectorFixture(script: """
    #!/bin/zsh
    while (( $# > 0 )); do
      if [[ "$1" == "--output" ]]; then printf 'not json at all' > "$2"; fi
      shift
    done
    """)
    defer { fixture.remove() }
    let corrector = LocalTranscriptCorrector(
        pythonExecutableURL: fixture.pythonURL,
        helperScriptURL: fixture.helperURL,
        modelDirectory: fixture.modelDirectory
    )
    await #expect(throws: SummarizerError.localOutputUnreadable) {
        _ = try await corrector.correct(transcript: "hi there", vocabulary: ["Kubernetes"], reference: nil)
    }
    #expect(!SummarizerError.localOutputUnreadable.localizedDescription.contains("Claude"))
}

// F475 Part 3 — the correction helper measures the transcript, vocabulary, and reference document
// together against the model's context window before loading it.
@Test("A too-long correction request is refused with the helper's own measured detail, verbatim (F475)")
func correctorRefusesATranscriptTooLongForContext() async throws {
    // No apostrophe: the fixture below embeds this JSON inside a single-quoted zsh string (a
    // fixture artifact — the real payload travels as a JSON file, never through a shell string).
    let detail = "This transcript needs about 55000 tokens, more than the 38400 available in the " +
        "model 40960-token context window with 2048 reserved for the response. Try a shorter " +
        "selection, or use Claude for long meetings."
    let fixture = try CorrectorFixture(outputJSON: """
    {"corrections":[],"warning":\(String(reflecting: detail)),"finishReason":"too_long","generatedTokens":0}
    """)
    defer { fixture.remove() }
    let corrector = LocalTranscriptCorrector(
        pythonExecutableURL: fixture.pythonURL,
        helperScriptURL: fixture.helperURL,
        modelDirectory: fixture.modelDirectory
    )
    await #expect(throws: SummarizerError.localInputTooLong(detail)) {
        _ = try await corrector.correct(transcript: "hi there", vocabulary: ["Kubernetes"], reference: nil)
    }
}

@Test("Cancelling a correction terminates its helper process")
func correctorCancellation() async throws {
    let fixture = try CorrectorFixture(script: "#!/bin/zsh\nexec sleep 120\n")
    defer { fixture.remove() }
    let corrector = LocalTranscriptCorrector(
        pythonExecutableURL: fixture.pythonURL,
        helperScriptURL: fixture.helperURL,
        modelDirectory: fixture.modelDirectory
    )
    let task = Task {
        try await corrector.correct(transcript: "hi there", vocabulary: ["Kubernetes"], reference: nil)
    }
    try await Task.sleep(for: .milliseconds(150))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test("Correction runtime completeness requires correct_local.py alongside the installed summarizer")
func correctionHelperInstalledPredicate() throws {
    let support = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetCorrectionRuntime-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: support) }
    try FileManager.default.createDirectory(
        at: SummarizerRuntime.managedDirectory(applicationSupport: support).appendingPathComponent("venv/bin"),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: SummarizerRuntime.modelDirectory(applicationSupport: support), withIntermediateDirectories: true
    )
    let python = SummarizerRuntime.pythonExecutable(applicationSupport: support)
    try Data("#!/bin/zsh\n".utf8).write(to: python)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
    try Data("helper".utf8).write(to: SummarizerRuntime.helperScript(applicationSupport: support))
    try Data("weights".utf8).write(
        to: SummarizerRuntime.modelDirectory(applicationSupport: support).appendingPathComponent("model.safetensors")
    )
    // Summarizer installed, but correct_local.py absent → correction not yet available.
    #expect(SummarizerRuntime.isInstalled(applicationSupport: support))
    #expect(!SummarizerRuntime.isCorrectionHelperInstalled(applicationSupport: support))
    try Data("corrector".utf8).write(to: SummarizerRuntime.correctionHelperScript(applicationSupport: support))
    #expect(SummarizerRuntime.isCorrectionHelperInstalled(applicationSupport: support))
}

@Test("TranscriptCorrection maps to a per-segment GlossaryCorrection wherever `from` appears (F165)")
func transcriptCorrectionMapsToSegments() {
    let segments = [
        TranscriptSegment(speaker: nil, start: 0, end: 1, text: "Kew Bernetes is great"),
        TranscriptSegment(speaker: nil, start: 1, end: 2, text: "we love Kew Bernetes"),
        TranscriptSegment(speaker: nil, start: 2, end: 3, text: "unrelated line"),
    ]
    let mapped = TranscriptCorrection.glossaryCorrections(
        from: [
            TranscriptCorrection(from: "Kew Bernetes", to: "Kubernetes"),
            TranscriptCorrection(from: "same", to: "same"),        // dropped: from == to
            TranscriptCorrection(from: "Missing", to: "X"),        // dropped: in no segment
        ],
        segments: segments
    )
    #expect(mapped == [
        GlossaryCorrection(segmentIndex: 0, from: "Kew Bernetes", to: "Kubernetes"),
        GlossaryCorrection(segmentIndex: 1, from: "Kew Bernetes", to: "Kubernetes"),
    ])
}

private struct CorrectorFixture {
    let directory: URL
    let pythonURL: URL
    let helperURL: URL
    let modelDirectory: URL
    let argumentsURL: URL
    let inputCaptureURL: URL

    init(script customScript: String? = nil, outputJSON: String? = nil) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperMeetCorrectTests-\(UUID().uuidString)", isDirectory: true)
        pythonURL = directory.appendingPathComponent("python")
        helperURL = directory.appendingPathComponent("correct_local.py")
        modelDirectory = directory.appendingPathComponent("model", isDirectory: true)
        argumentsURL = directory.appendingPathComponent("arguments.txt")
        inputCaptureURL = directory.appendingPathComponent("input-capture.json")

        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try Data("helper".utf8).write(to: helperURL)
        try Data("weights".utf8).write(to: modelDirectory.appendingPathComponent("model.safetensors"))

        let payload = outputJSON ?? #"{"corrections":[],"warning":null,"finishReason":"stop","generatedTokens":1}"#
        let defaultScript = """
        #!/bin/zsh
        set -euo pipefail
        printf '%s\\n' "$@" > '\(argumentsURL.path)'
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
