import Foundation

/// One proposed transcript correction: replace `from` with `to`. Reviewed before any apply (F165).
public struct TranscriptCorrection: Sendable, Equatable, Codable {
    public let from: String
    public let to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }

    /// Maps whole-transcript corrections onto per-segment `GlossaryCorrection`s — one per segment that
    /// contains `from` — so LLM corrections flow through the exact same review + apply path as F82's
    /// glossary corrections (`GlossaryCorrector.apply`, which never touches audio). A consistent
    /// mis-transcription that recurs across segments is fixed everywhere it appears.
    public static func glossaryCorrections(
        from corrections: [TranscriptCorrection],
        segments: [TranscriptSegment]
    ) -> [GlossaryCorrection] {
        var result: [GlossaryCorrection] = []
        for correction in corrections where !correction.from.isEmpty && correction.from != correction.to {
            for (index, segment) in segments.enumerated() where segment.text.contains(correction.from) {
                result.append(GlossaryCorrection(
                    segmentIndex: index, from: correction.from, to: correction.to
                ))
            }
        }
        return result
    }
}

/// An on-device LLM pass that proposes spelling/term corrections for a transcript, guided by the
/// user's business vocabulary and an optional reference document (F165). It reuses the F164
/// `Runtime/Summarizer` model + venv via the `correct_local.py` helper, mirroring `LocalSummarizer`.
/// It proposes only — nothing is applied here; the user reviews every correction (like F82's glossary
/// corrections), and the raw recording is never touched.
public struct LocalTranscriptCorrector: Sendable {
    private let pythonExecutableURL: URL
    private let helperScriptURL: URL
    private let modelDirectory: URL
    private let maxTokens: Int

    public init(
        pythonExecutableURL: URL = SummarizerRuntime.pythonExecutable(),
        helperScriptURL: URL = SummarizerRuntime.correctionHelperScript(),
        modelDirectory: URL = SummarizerRuntime.modelDirectory(),
        maxTokens: Int = 2_048
    ) {
        self.pythonExecutableURL = pythonExecutableURL
        self.helperScriptURL = helperScriptURL
        self.modelDirectory = modelDirectory
        self.maxTokens = maxTokens
    }

    public func correct(
        transcript: String,
        vocabulary: [String],
        reference: String?
    ) async throws -> [TranscriptCorrection] {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let referenceText = reference?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nothing to correct, or nothing to correct *toward* — skip the model entirely.
        guard !trimmed.isEmpty, !terms.isEmpty || !(referenceText ?? "").isEmpty else { return [] }
        guard runtimeIsComplete else { throw SummarizerError.modelNotInstalled }
        try Task.checkCancellation()

        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperMeet-Correct-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let inputURL = workingDirectory.appendingPathComponent("request.json")
        let outputURL = workingDirectory.appendingPathComponent("corrections.json")
        let requestBody: [String: String] = [
            "systemPrompt": Self.systemPrompt,
            "transcript": Self.userContent(transcript: trimmed, vocabulary: terms, reference: referenceText),
        ]
        try JSONSerialization.data(withJSONObject: requestBody).write(to: inputURL)

        let arguments = [
            helperScriptURL.path,
            "--model", modelDirectory.path,
            "--input", inputURL.path,
            "--output", outputURL.path,
            "--max-tokens", String(maxTokens),
        ]
        let log = try await run(arguments: arguments)
        try Task.checkCancellation()

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw SummarizerError.helperFailed(
                log.isEmpty ? "The correction helper produced no output." : String(log.suffix(2_000))
            )
        }
        guard let payload = try? JSONDecoder().decode(
            LocalCorrectionOutput.self,
            from: Data(contentsOf: outputURL)
        ) else {
            throw SummarizerError.unreadableResponse
        }
        // Keep only corrections whose `from` still appears in the transcript, so a hallucinated span
        // can never be applied. `to` must differ from `from`.
        return payload.corrections.filter { correction in
            !correction.from.isEmpty
                && correction.from != correction.to
                && trimmed.contains(correction.from)
        }
    }

    /// The correction instructions. Asks for a strict JSON object and forbids paraphrasing so this can
    /// never rewrite the meeting — only fix mis-transcribed spans toward the vocabulary/reference.
    static let systemPrompt = """
    You correct speech-recognition errors in a meeting transcript. You are given the transcript, a list \
    of correct business vocabulary terms, and optionally a reference document. Find spans in the \
    transcript that were mis-transcribed and should be one of the vocabulary terms or a spelling found \
    in the reference. Only fix clear recognition errors (wrong spelling of a name, product, or term). \
    Do NOT paraphrase, translate, reword, summarize, or change meaning, punctuation, or anything that \
    is already correct. Keep the transcript's original language.
    Respond with ONLY a JSON object of the form {"corrections": [{"from": "<exact transcript text>", \
    "to": "<correction>"}]} — "from" must be copied verbatim from the transcript. Use an empty array \
    if nothing needs fixing. Write nothing before or after the JSON, and no markdown code fences.
    """

    /// Assembles the user turn: the transcript, the vocabulary, and the optional reference.
    static func userContent(transcript: String, vocabulary: [String], reference: String?) -> String {
        var parts = ["Transcript:\n\(transcript)"]
        if !vocabulary.isEmpty {
            parts.append("Correct business vocabulary:\n" + vocabulary.map { "- \($0)" }.joined(separator: "\n"))
        }
        if let reference, !reference.isEmpty {
            parts.append("Reference document:\n\(reference)")
        }
        return parts.joined(separator: "\n\n")
    }

    private var runtimeIsComplete: Bool {
        let files = FileManager.default
        return files.isExecutableFile(atPath: pythonExecutableURL.path)
            && files.fileExists(atPath: helperScriptURL.path)
            && files.fileExists(
                atPath: modelDirectory.appendingPathComponent("model.safetensors").path
            )
    }

    /// Runs the helper, draining its merged stdout+stderr and reading the result from `--output`.
    /// Same shape as `LocalSummarizer.run` (spawns no descendant processes; terminating the child
    /// fully cancels it).
    private func run(arguments: [String]) async throws -> String {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = pythonExecutableURL
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        process.environment = LocalSummarizer.makeEnvironment()
        let cancellation = ProcessCancellationController(process: process)

        let handle = pipe.fileHandleForReading
        let processExited = armedExitStream(for: process)
        let dataStream = AsyncStream<Data> { continuation in
            handle.readabilityHandler = { fileHandle in
                let data = fileHandle.availableData
                if data.isEmpty {
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
            continuation.onTermination = { _ in
                handle.readabilityHandler = nil
            }
        }

        return try await withTaskCancellationHandler {
            try cancellation.runUnlessCancelled()

            var logData = Data()
            for await data in dataStream {
                logData.append(data)
                if logData.count > 200_000 {
                    logData = logData.suffix(100_000)
                }
            }
            // Wait for the child to exit via terminationHandler, not the blocking waitUntilExit()
            // (which wedges a Swift cooperative thread under load — see armedExitStream).
            for await _ in processExited {}
            handle.readabilityHandler = nil

            let log = String(decoding: logData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else {
                throw SummarizerError.helperFailed(
                    log.isEmpty
                        ? "The correction helper exited with status \(process.terminationStatus)."
                        : String(log.suffix(2_000))
                )
            }
            return log
        } onCancel: {
            cancellation.cancel()
        }
    }
}

/// The `correct_local.py` `--output` payload. `warning`/`finishReason`/`generatedTokens` are diagnostics.
struct LocalCorrectionOutput: Decodable {
    let corrections: [TranscriptCorrection]
    let warning: String?
    let finishReason: String?
    let generatedTokens: Int?
}
