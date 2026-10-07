import Foundation

/// Locates the on-device summarization runtime under
/// `~/Library/Application Support/WhisperMeet/Runtime/Summarizer/` and picks which model to install.
///
/// It is deliberately **separate** from `QwenASRRuntime`: local summaries are the *default*
/// summarizer (F164), so they must not require the opt-in Qwen3-ASR runtime to be installed. This
/// gives the summarizer its own `mlx_lm` venv, model, and helper, mirroring the Qwen layout.
public struct SummarizerRuntime: Sendable {
    /// Default on-device model on Macs with enough memory (Apache-2.0, ~4.5 GB, 4-bit, mlx_lm text).
    public static let defaultRepository = "mlx-community/Qwen3-8B-4bit"
    /// Fallback on memory-constrained Macs (Apache-2.0, ~2.3 GB, 4-bit).
    public static let fallbackRepository = "mlx-community/Qwen3-4B-4bit"
    /// Physical-RAM threshold for the larger default model: 16 GiB.
    public static let defaultModelMinimumBytes: UInt64 = 16 * 1024 * 1024 * 1024

    /// mlx runs only on Apple silicon, so on-device summaries are Apple-silicon only (like Qwen3-ASR).
    public static var isSupportedOnCurrentMac: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    public static func managedDirectory(applicationSupport: URL? = nil) -> URL {
        LocalWhisperRuntime.managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("Summarizer", isDirectory: true)
    }

    public static func pythonExecutable(applicationSupport: URL? = nil) -> URL {
        managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("venv/bin/python")
    }

    public static func helperScript(applicationSupport: URL? = nil) -> URL {
        managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("summarize_local.py")
    }

    /// The transcript-correction helper, installed alongside the summarizer in the same runtime (F165).
    public static func correctionHelperScript(applicationSupport: URL? = nil) -> URL {
        managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("correct_local.py")
    }

    /// The dictation-refinement helper (F200), installed alongside the summarizer in the same runtime.
    public static func refineHelperScript(applicationSupport: URL? = nil) -> URL {
        managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("refine_server.py")
    }

    public static func modelDirectory(applicationSupport: URL? = nil) -> URL {
        managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("model", isDirectory: true)
    }

    public static func isInstalled(applicationSupport: URL? = nil) -> Bool {
        let files = FileManager.default
        return files.isExecutableFile(atPath: pythonExecutable(
            applicationSupport: applicationSupport
        ).path)
            && files.fileExists(atPath: helperScript(
                applicationSupport: applicationSupport
            ).path)
            && files.fileExists(atPath: modelDirectory(
                applicationSupport: applicationSupport
            ).appendingPathComponent("model.safetensors").path)
    }

    /// Whether the runtime is installed AND carries the F165 correction helper. Kept separate from
    /// `isInstalled` so an F164-era summarizer install (which predates `correct_local.py`) still reports
    /// installed for summaries; correction is gated until the helper reaches disk, which the launch
    /// helper-sync does (F643) — no model update is needed, only a launch of a build that bundles it.
    public static func isCorrectionHelperInstalled(applicationSupport: URL? = nil) -> Bool {
        isInstalled(applicationSupport: applicationSupport)
            && FileManager.default.fileExists(
                atPath: correctionHelperScript(applicationSupport: applicationSupport).path
            )
    }

    /// Whether the runtime is installed AND carries the F200 refine helper. Same shape as
    /// `isCorrectionHelperInstalled`: an older install stays valid for summaries; dictation
    /// refinement is gated until the helper reaches disk (the launch helper-sync writes it).
    public static func isRefineHelperInstalled(applicationSupport: URL? = nil) -> Bool {
        isInstalled(applicationSupport: applicationSupport)
            && FileManager.default.fileExists(
                atPath: refineHelperScript(applicationSupport: applicationSupport).path
            )
    }

    /// The mlx-community repo to install, chosen by physical RAM: the 8B default on ≥16 GiB Macs, the
    /// 4B fallback below that. `physicalMemory` is injected (default `ProcessInfo.physicalMemory`) so
    /// the branch is unit-testable without specific hardware — the first RAM probe in the codebase.
    public static func recommendedRepository(
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> String {
        physicalMemory >= defaultModelMinimumBytes ? defaultRepository : fallbackRepository
    }
}

/// An on-device `MeetingSummarizer` backed by a local `mlx_lm` model via the `summarize_local.py`
/// helper (F164). It is the private, keyless default; `ClaudeSummarizer` remains the opt-in cloud
/// upgrade behind the same protocol. The helper runs under `ProcessGroupRunner`, so cancelling stops
/// it and anything it spawned, and a helper that goes silent is stopped (F512).
public struct LocalSummarizer: MeetingSummarizer {
    /// How long the helper may print nothing before it is presumed wedged and stopped (F512).
    ///
    /// Derived from what the helper reports, not from how long a summary takes: it prints before and
    /// after loading the model, every 15 s during the load while the load is moving (a major fault, a
    /// block read, or CPU on another thread; `load_made_progress`, F606), after every prompt chunk of
    /// mlx_lm's `prefill_step_size` (2,048 tokens), and while generating every 32 tokens or 5
    /// seconds. So ten silent minutes means the model load made no progress for ten minutes, or one
    /// prompt chunk or one token took ten minutes. A load that spins the CPU without progressing
    /// still reads as moving, and is stopped only by Cancel.
    ///
    /// Measured 2026-09-24 with the installed Qwen3-8B-4bit on an 18 GB M3 Pro with 15.5 GB of swap in
    /// use, on a synthetic 32,323-token transcript: the longest silence was 40 s, one prompt chunk
    /// near the end of the prefill. A count-only cadence was not enough — 32 generated tokens took
    /// 146 s in the same conditions, which is why generation also reports on time.
    public static let defaultStallTimeout: TimeInterval = 600

    /// Runs the helper — the interpreter, its arguments, its environment, and how long it may stay
    /// silent — and returns its exit status and merged output. The default spawns it under
    /// `ProcessGroupRunner`; a test injects one that reports a stall at once instead of sitting one
    /// out (F512).
    public typealias HelperRunner = @Sendable (
        _ executableURL: URL, _ arguments: [String], _ environment: [String: String], _ stallTimeout: TimeInterval
    ) async throws -> ProcessGroupRunner.Outcome

    public static let defaultHelperRunner: HelperRunner = { executableURL, arguments, environment, stallTimeout in
        try await ProcessGroupRunner().run(
            executableURL: executableURL, arguments: arguments, environment: environment, stallTimeout: stallTimeout
        )
    }

    private let pythonExecutableURL: URL
    private let helperScriptURL: URL
    private let modelDirectory: URL
    private let maxTokens: Int
    private let stallTimeout: TimeInterval
    private let runHelper: HelperRunner

    public init(
        pythonExecutableURL: URL = SummarizerRuntime.pythonExecutable(),
        helperScriptURL: URL = SummarizerRuntime.helperScript(),
        modelDirectory: URL = SummarizerRuntime.modelDirectory(),
        maxTokens: Int = 2_048,
        stallTimeout: TimeInterval = LocalSummarizer.defaultStallTimeout,
        runHelper: @escaping HelperRunner = LocalSummarizer.defaultHelperRunner
    ) {
        self.pythonExecutableURL = pythonExecutableURL
        self.helperScriptURL = helperScriptURL
        self.modelDirectory = modelDirectory
        self.maxTokens = maxTokens
        self.stallTimeout = stallTimeout
        self.runHelper = runHelper
    }

    public func summarize(
        transcript: String,
        language: String?,
        style: SummaryStyle,
        template: MeetingTemplate
    ) async throws -> MeetingSummary {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SummarizerError.emptyTranscript }
        guard runtimeIsComplete else { throw SummarizerError.modelNotInstalled }
        try Task.checkCancellation()

        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperMeet-Summary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let inputURL = workingDirectory.appendingPathComponent("request.json")
        let outputURL = workingDirectory.appendingPathComponent("summary.json")
        let requestBody: [String: String] = [
            "systemPrompt": Self.systemPrompt(
                language: language, style: style, template: template, script: ScriptDrift.form(of: trimmed)
            ),
            "transcript": trimmed,
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
                log.isEmpty ? "The local summarizer produced no output." : String(log.suffix(2_000))
            )
        }
        guard let payload = try? JSONDecoder().decode(
            LocalSummaryOutput.self,
            from: Data(contentsOf: outputURL)
        ) else {
            throw SummarizerError.localOutputUnreadable
        }
        // F475 Part 1: `parse_summary` DEGRADES rather than raises — truncated JSON (a
        // `--max-tokens` stop mid-array) or non-JSON text becomes a "clean-looking" payload with
        // `warning`/`finishReason` set. Before this check, `LocalSummarizer.summarize` read only
        // the three content fields and ignored both diagnostics, so a truncated array or the
        // model's raw, unparsed text was stored and shown as a good summary. Checked before the
        // empty-result guard below: a refusal here must not be shadowed by an unrelated cause.
        if let refusal = Self.localOutputRefusal(warning: payload.warning, finishReason: payload.finishReason) {
            throw refusal
        }
        let summary = MeetingSummary(
            summary: payload.summary,
            keyPoints: payload.keyPoints,
            // The local helper still emits action items as plain strings; F177 links each to its
            // supporting transcript moment later, in AppModel, from the meeting's segments.
            actionItems: payload.actionItems.map { ActionItem(text: $0) }
        )
        // A completely empty result is an error; anything past the refusal above is a clean result
        // the model is confident in, not a degraded fallback.
        guard !summary.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !summary.keyPoints.isEmpty
            || !summary.actionItems.isEmpty else {
            throw SummarizerError.emptyResponse
        }
        return summary
    }

    /// The raw answer text for an Ask Meetings question, grounded on `passages` (F182).
    ///
    /// Reuses the summary helper unchanged: it takes a system prompt and a user message and returns
    /// a JSON object, so the answer travels in its `summary` field. The caller decides whether the
    /// text may be shown — `MeetingAnswerPolicy.evaluate` — this only runs the model.
    public func answerText(question: String, passages: [CitedResult]) async throws -> String {
        guard !passages.isEmpty else { throw SummarizerError.emptyTranscript }
        guard runtimeIsComplete else { throw SummarizerError.modelNotInstalled }
        try Task.checkCancellation()

        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperMeet-Answer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let inputURL = workingDirectory.appendingPathComponent("request.json")
        let outputURL = workingDirectory.appendingPathComponent("answer.json")
        let requestBody: [String: String] = [
            "systemPrompt": MeetingAnswerPrompt.system + "\n" + Self.answerFormatInstruction,
            "transcript": MeetingAnswerPrompt.grounding(question: question, passages: passages),
        ]
        try JSONSerialization.data(withJSONObject: requestBody).write(to: inputURL)
        let log = try await run(arguments: [
            helperScriptURL.path,
            "--model", modelDirectory.path,
            "--input", inputURL.path,
            "--output", outputURL.path,
            "--max-tokens", "400",
        ])
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw SummarizerError.helperFailed(
                log.isEmpty ? "The local model produced no output." : String(log.suffix(2_000))
            )
        }
        guard let payload = try? JSONDecoder().decode(LocalSummaryOutput.self, from: Data(contentsOf: outputURL)) else {
            throw SummarizerError.localOutputUnreadable
        }
        // An *answer* cannot take the "a degraded result beats a dead end" trade `summarize` now
        // makes only for a genuinely clean payload (F332, and F475 Part 1 gave `summarize` the same
        // refusal). `parse_summary` degrades unparseable model output into a raw-text summary with
        // a warning, and `--max-tokens 400` can stop the model mid-sentence (`finishReason ==
        // "length"`); either way the result would otherwise be shown with the same authority as a
        // clean one as long as it happens to contain one `[n]`. The user is left with the passages,
        // which are what was said — the same place every other refusal leaves them.
        if let refusal = Self.answerRefusal(warning: payload.warning, finishReason: payload.finishReason) {
            throw refusal
        }
        return payload.summary
    }

    /// Why a helper payload may not be shown as an answer, or nil when it may (F332).
    ///
    /// Pure so the rule is testable without a 5 GB model and a subprocess. The finish reason comes
    /// from `mlx_lm`'s `stream_generate`, which reports `"length"` when it stopped at `--max-tokens`
    /// rather than at an end-of-turn token.
    static func answerRefusal(warning: String?, finishReason: String?) -> SummarizerError? {
        // F598: before the warning check, which would otherwise wrap it as a degraded answer.
        if finishReason == Self.modelUnreadableFinishReason {
            return .localModelUnreadable(warning ?? Self.modelUnreadableFallback)
        }
        if let warning, !warning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .answerDegraded(warning)
        }
        if finishReason == "length" { return .answerTruncated }
        return nil
    }

    /// `answerRefusal`'s sibling for the summarize and correct paths (F475 Part 1). Same shape and
    /// same reason to be pure, mapping to the generic `.localOutputTruncated`/`.localOutputDegraded`
    /// cases rather than `.answerTruncated`/`.answerDegraded`, whose copy says "the answer" and "the
    /// passages" — neither concept exists here. Shared by `LocalSummarizer.summarize` and
    /// `LocalTranscriptCorrector.correct` so the two helpers cannot drift on what counts as degraded.
    static func localOutputRefusal(warning: String?, finishReason: String?) -> SummarizerError? {
        // F475 Part 3: checked first and specifically, because `finishReason == "too_long"` means
        // the helper refused BEFORE calling the model at all (measured against the real tokenizer
        // and the model's context window) — a different situation from a warning about output the
        // model actually produced, and `.localInputTooLong`'s copy is the detail verbatim, not
        // wrapped in "the model's output could not be read cleanly (…)".
        if finishReason == "too_long" {
            return .localInputTooLong(warning ?? "This transcript is too long for the on-device model.")
        }
        // F598: the helper could not read the model's own files, so it never ran the model either;
        // "try again" (`.localOutputDegraded`'s advice) cannot help a broken install.
        if finishReason == Self.modelUnreadableFinishReason {
            return .localModelUnreadable(warning ?? Self.modelUnreadableFallback)
        }
        if let warning, !warning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .localOutputDegraded(warning)
        }
        if finishReason == "length" { return .localOutputTruncated }
        return nil
    }

    /// `summarize_local.py`/`correct_local.py`'s `MODEL_UNREADABLE` (F598).
    static let modelUnreadableFinishReason = "model_unreadable"
    /// Only for a payload that carries the finish reason without its warning; the helpers always
    /// write both.
    static let modelUnreadableFallback = "The on-device model's files could not be read. Use "
        + "Repair or Update under Summaries in Settings, then try again."

    static let answerFormatInstruction = """
    Respond with ONLY a JSON object with exactly these keys: "summary" (a string holding your \
    answer, citations included), "keyPoints" (an empty array), and "actionItems" (an empty array). \
    Do not write anything before or after the JSON object, and do not wrap it in markdown code fences.
    """

    /// The local prompt reuses `ClaudeSummarizer.systemPrompt` verbatim — the single source of truth
    /// for the output fields and the do-not-translate clause — then appends an explicit JSON-format
    /// directive, because a local model has no enforced structured-output schema like Claude's.
    static func systemPrompt(
        language: String?,
        style: SummaryStyle,
        template: MeetingTemplate = .general,
        script: ChineseScriptForm? = nil
    ) -> String {
        ClaudeSummarizer.systemPrompt(language: language, style: style, template: template, script: script)
            + "\n" + jsonFormatInstruction
    }

    static let jsonFormatInstruction = """
    Respond with ONLY a JSON object with exactly these keys: "summary" (a string), "keyPoints" (an \
    array of strings), and "actionItems" (an array of strings). Do not write anything before or \
    after the JSON object, and do not wrap it in markdown code fences.
    """

    private var runtimeIsComplete: Bool {
        let files = FileManager.default
        return files.isExecutableFile(atPath: pythonExecutableURL.path)
            && files.fileExists(atPath: helperScriptURL.path)
            && files.fileExists(
                atPath: modelDirectory.appendingPathComponent("model.safetensors").path
            )
    }

    /// Keeps the model fully offline and unbuffered so its stderr progress streams live. Mirrors
    /// `QwenASRClient.makeEnvironment`.
    static func makeEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        return environment
    }

    /// Runs the helper and returns its merged stdout+stderr log; the result itself is read from
    /// `--output`, not stdout (F24).
    ///
    /// Through `runHelper` — by default `ProcessGroupRunner` (F512) rather than a bare `Process`, for
    /// its stall watchdog: a helper that printed nothing — a wedged mlx, a load stuck waiting (F606) —
    /// used to hold the one summary slot, and with it every Summarize and every Ask answer, until the
    /// app was quit. Cancelling still stops the helper, now as a process group. The runner's own
    /// errors describe a download, so both are restated here in the summarizer's words.
    private func run(arguments: [String]) async throws -> String {
        let outcome: ProcessGroupRunner.Outcome
        do {
            outcome = try await runHelper(pythonExecutableURL, arguments, Self.makeEnvironment(), stallTimeout)
        } catch ProcessGroupRunnerError.stalled(let seconds) {
            throw SummarizerError.helperStalled(seconds)
        } catch ProcessGroupRunnerError.spawnFailed(let code) {
            throw SummarizerError.helperFailed("The summarizer helper could not be started (errno \(code)).")
        }
        let log = outcome.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard outcome.exitStatus == 0 else {
            throw SummarizerError.helperFailed(
                log.isEmpty
                    ? "The summarizer helper exited with status \(outcome.exitStatus)."
                    : String(log.suffix(2_000))
            )
        }
        return log
    }
}

/// The `summarize_local.py` `--output` payload. `warning`/`finishReason`/`generatedTokens` are
/// diagnostics; the three content fields decode straight into `MeetingSummary`.
struct LocalSummaryOutput: Decodable {
    let summary: String
    let keyPoints: [String]
    let actionItems: [String]
    let warning: String?
    let finishReason: String?
    let generatedTokens: Int?
}
