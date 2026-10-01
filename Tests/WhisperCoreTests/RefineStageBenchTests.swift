import Foundation
import Testing
@testable import WhisperCore

// F631 — the refine-stage bench's pure half, tested in the default gate.
//
// F589 measured what Quick Dictation's refinement does to code-switched words with a throwaway
// driver it could not commit. `RefineStageBench` is the committed replacement's arithmetic: the
// per-word verdict, the input the app would send, and the tables. The verdict is a port of
// `Scripts/bench/dictation-ab.py`'s, so the raw column here and that script's `--words` table mean
// the same thing by "kept"; F291 is the warning about ports that diverge, so each expected verdict
// below is the answer that script's own `word_diff` gave for the same pair when F631 ran it, and
// `thePortStillReadsDictationAbsRule` fails if the script's rule changes under it.

private enum Fixture {
    static let cs3Raw = "这个 bug 已经 fix 了，可以 merge 了。"
    /// F589's reproduced refinement of cs3 (both engines, Automatic): two of three loanwords gone.
    static let cs3Refined = "这个 bug 已经修复了，可以合并了。"
    static let encs1Raw = "Please send the会议纪要to the whole team before周五."
    /// F589's reproduced refinement of encs1: both embedded words translated into English.
    static let encs1Translated = "Please send the meeting minutes to the whole team before Friday."

    static func clip(_ id: String, _ text: String, words: [(String, Bool)]? = nil,
                     reported: String? = nil) -> RefineStageBench.RawClip {
        RefineStageBench.RawClip(
            clip: id, text: text, reportedLanguage: reported,
            words: words?.map { RefineStageBench.RawWord(word: $0.0, kept: $0.1) },
            helperError: nil
        )
    }
}

@Suite("Refine-stage bench: verdicts, input and tables (F631)")
struct RefineStageBenchTableTests {
    @Test("A refinement that translates two of cs3's three loanwords is two drops by the refiner, none by the recognizer (F631)")
    func cs3PartialTranslationIsTwoRefinementDrops() {
        let verdicts = RefineStageBench.wordVerdicts(
            words: ["bug", "fix", "merge"], raw: Fixture.cs3Raw, delivered: Fixture.cs3Refined
        )
        let expected: [RefineStageBench.WordVerdict] = [
            .init(word: "bug", keptInRaw: true, keptInDelivered: true),
            .init(word: "fix", keptInRaw: true, keptInDelivered: false),
            .init(word: "merge", keptInRaw: true, keptInDelivered: false),
        ]
        #expect(verdicts == expected)
    }

    @Test("encs1's two embedded Mandarin words translated into English are both dropped (F631)")
    func encs1TranslationDropsBothWords() {
        let verdicts = RefineStageBench.wordVerdicts(
            words: ["会议纪要", "周五"], raw: Fixture.encs1Raw, delivered: Fixture.encs1Translated
        )
        let expected: [RefineStageBench.WordVerdict] = [
            .init(word: "会议纪要", keptInRaw: true, keptInDelivered: false),
            .init(word: "周五", keptInRaw: true, keptInDelivered: false),
        ]
        #expect(verdicts == expected)
    }

    @Test("Kept means dictation-ab.py's kept: NFKC, lowercase, letters and digits only, then a substring (F631)")
    func theVerdictIsDictationAbsNormalizedSubstring() {
        // Every expectation here is what `dictation-ab.py`'s `word_diff` answered for the same pair.
        #expect(RefineStageBench.isKept("fix", in: "这个 bug 已经 fixed 了，可以 merge 了。"))
        #expect(!RefineStageBench.isKept("王老师", in: "I'll ping Wang老师 about the作业 tonight."))
        #expect(RefineStageBench.isKept("作业", in: "I'll ping Wang老师 about the作业 tonight."))
        #expect(RefineStageBench.isKept("\u{FF26}\u{FF29}\u{FF38}", in: "Fix it"))
        #expect(RefineStageBench.isKept("Deadline", in: "我们的 deadline 是这个星期五。"))
        #expect(RefineStageBench.isKept("会议纪要", in: "会议 纪要。"))
        #expect(RefineStageBench.isKept("\u{FF12}\u{FF10}\u{FF12}\u{FF16}", in: "in 2026"))
        // A word that normalises to nothing is never kept, as `bool(word_norm)` says.
        #expect(!RefineStageBench.isKept("", in: "anything"))
        #expect(!RefineStageBench.isKept("。", in: "。"))
        // Python's isalnum is by general category, so a spacing vowel sign (Mc) is dropped. Swift's
        // `isAlphabetic` keeps it, which is the divergence F291 warns of: with it, this is "dropped".
        #expect(RefineStageBench.isKept("\u{0915}\u{093F}", in: "\u{0915}"))
    }

    @Test("The port still reads dictation-ab.py's rule as it is written (F631)")
    func thePortStillReadsDictationAbsRule() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhisperCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Scripts/bench/dictation-ab.py")
        // Code lines only: a commented-out copy of a rule is not the rule (F285).
        let codeLines = Set(
            try String(contentsOf: script, encoding: .utf8)
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("#") }
        )
        let rule = [
            #"text = unicodedata.normalize("NFKC", text).lower()"#,
            #"return "".join(c for c in text if c.isalnum() or c.isspace()).split()"#,
            #"hyp_norm = "".join(normalize(hypothesis))"#,
            #"word_norm = "".join(normalize(word))"#,
            "kept = bool(word_norm) and word_norm in hyp_norm",
        ]
        for line in rule {
            #expect(
                codeLines.contains(line),
                "dictation-ab.py no longer says `\(line)`. Change RefineStageBench.isKept to match, or the two tables stop meaning the same thing by kept."
            )
        }
    }

    @Test("Raw runs decode as dictation-ab.py writes them, and Automatic is not confused with unrecorded (F631)")
    func rawRunsDecodeAsDictationAbWritesThem() throws {
        let json = """
        [
          {"engine": "qwen3-asr-1.7b-8bit", "label": "Qwen3-ASR 1.7B", "language": null,
           "cold_seconds": 6.4, "clips": [
             {"clip": "encs4", "lang": "encs", "seconds": 0.6, "text": "I'll ping Wang老师 about the作业 tonight.",
              "reference": "I'll ping 王老师 about the 作业 tonight.", "error_rate": 0.148,
              "helper_error": null, "reported_language": null,
              "words": [{"word": "王老师", "kept": false}, {"word": "作业", "kept": true}]},
             {"clip": "en1", "lang": "en", "seconds": 0.5, "text": "Can you send me the report?",
              "reference": "Can you send me the report?", "error_rate": 0.0,
              "helper_error": null, "reported_language": "en"}
           ]},
          {"engine": "turbo", "label": "Whisper Turbo", "language": "English",
           "cold_seconds": 3.1, "clips": []},
          {"engine": "qwen3-asr-1.7b-8bit", "label": "Qwen3-ASR 1.7B",
           "cold_seconds": 6.4, "clips": []}
        ]
        """
        let runs = try RefineStageBench.decodeRuns(from: Data(json.utf8))
        try #require(runs.count == 3)

        let expectedSettings: [RefineStageBench.LanguageSetting] = [
            .automatic, .pinned("English"), .notRecorded,
        ]
        #expect(runs.map(\.language) == expectedSettings)
        let expectedLabels: [String] = [
            "Qwen3-ASR 1.7B, Automatic", "Whisper Turbo, English",
            "Qwen3-ASR 1.7B, language not recorded",
        ]
        #expect(runs.map(RefineStageBench.conditionLabel(for:)) == expectedLabels)

        let encs4 = runs[0].clips[0]
        #expect(encs4.clip == "encs4")
        #expect(encs4.reportedLanguage == nil)
        #expect(encs4.words == [
            RefineStageBench.RawWord(word: "王老师", kept: false),
            RefineStageBench.RawWord(word: "作业", kept: true),
        ])
        // A clip without a "words" list (en, zh) still decodes; it simply has no per-word rows.
        #expect(runs[0].clips[1].words == nil)
        #expect(runs[0].clips[1].reportedLanguage == "en")
    }

    @Test("The refiner is sent what the app sends: the cleaned text and DictationResult's language code (F631)")
    func theRefinerIsSentWhatTheAppSends() {
        // A pinned helper echoes the language NAME; the app normalises it to a code (F447).
        #expect(RefineStageBench.refinerInput(for: Fixture.clip("x", "  Please  send\nthe会议纪要 ", reported: "English"))
            == RefineStageBench.RefinerInput(text: "Please send the会议纪要", languageCode: "en"))
        // Automatic Qwen reports no language at all, and the refiner is told none.
        #expect(RefineStageBench.refinerInput(for: Fixture.clip("x", "帮我 schedule 一个 meeting", reported: nil))
            == RefineStageBench.RefinerInput(text: "帮我 schedule 一个 meeting", languageCode: nil))
        #expect(RefineStageBench.refinerInput(for: Fixture.clip("x", "我们的 deadline", reported: "zh"))?.languageCode
            == "zh")
        // Production does not refine an empty transcript, so neither does the bench.
        #expect(RefineStageBench.refinerInput(for: Fixture.clip("x", " \n ")) == nil)
    }

    @Test("A raw verdict this port and dictation-ab.py disagree on is named, not averaged away (F631)")
    func aDisagreementWithDictationAbIsNamed() throws {
        let agreeing = RefineStageBench.RawRun(
            engine: "e", label: "E", language: .automatic,
            clips: [Fixture.clip("encs4", "I'll ping Wang老师 about the作业 tonight.",
                                 words: [("王老师", false), ("作业", true)])]
        )
        #expect(RefineStageBench.rawVerdictDisagreements(in: agreeing).isEmpty)

        let disagreeing = RefineStageBench.RawRun(
            engine: "e", label: "E", language: .automatic,
            clips: [Fixture.clip("encs4", "I'll ping Wang老师 about the作业 tonight.",
                                 words: [("王老师", true), ("作业", true)])]
        )
        let named = RefineStageBench.rawVerdictDisagreements(in: disagreeing)
        try #require(named.count == 1)
        #expect(named[0].contains("encs4"))
        #expect(named[0].contains("王老师"))
    }

    @Test("The prompt column names which prompt the refiner built, read off the prompt builder itself (F631)")
    func thePromptColumnNamesThePrompt() {
        #expect(RefineStageBench.promptLanguage(of: DictationRefinePrompt.system(languageCode: nil)) == "generic")
        #expect(RefineStageBench.promptLanguage(of: DictationRefinePrompt.system(languageCode: "en")) == "en")
        #expect(RefineStageBench.promptLanguage(of: DictationRefinePrompt.system(languageCode: "zh")) == "zh")
        #expect(RefineStageBench.promptLanguage(
            of: DictationRefinePrompt.system(languageCode: "zh", script: .simplified)) == "zh")
        #expect(RefineStageBench.promptLanguage(of: "something else entirely") == "other")
        #expect(RefineStageBench.promptLanguage(of: nil) == "—")
    }

    @Test("The tables show each word's fate and what refinement lost or gained, per condition (F631)")
    func theTablesShowEachWordsFate() {
        let cs3 = RefineStageBench.result(
            for: Fixture.clip("cs3", Fixture.cs3Raw, words: [("bug", true), ("fix", true), ("merge", true)]),
            input: RefineStageBench.RefinerInput(text: Fixture.cs3Raw, languageCode: nil),
            attempt: RefineAttempt(text: Fixture.cs3Refined, outcome: .refined),
            reply: Fixture.cs3Refined,
            systemPrompt: DictationRefinePrompt.system(languageCode: "zh", script: .simplified)
        )
        let encs1 = RefineStageBench.result(
            for: Fixture.clip("encs1", Fixture.encs1Raw, words: [("会议纪要", true), ("周五", true)]),
            input: RefineStageBench.RefinerInput(text: Fixture.encs1Raw, languageCode: nil),
            attempt: RefineAttempt(text: Fixture.encs1Raw, outcome: .rawRejected),
            reply: Fixture.encs1Translated,
            systemPrompt: DictationRefinePrompt.system(languageCode: nil)
        )
        // A refinement that restores a word the recognizer lost is a gain, and is shown as one.
        let encs4 = RefineStageBench.result(
            for: Fixture.clip("encs4", "I'll ping Wang老师 about the作业 tonight.",
                              words: [("王老师", false), ("作业", true)]),
            input: RefineStageBench.RefinerInput(
                text: "I'll ping Wang老师 about the作业 tonight.", languageCode: nil),
            attempt: RefineAttempt(text: "I'll ping 王老师 about the 作业 tonight.", outcome: .refined),
            reply: "I'll ping 王老师 about the 作业 tonight.",
            systemPrompt: DictationRefinePrompt.system(languageCode: nil)
        )
        // An empty transcript is not refined by the app, so no request and no outcome.
        let silent = RefineStageBench.result(
            for: Fixture.clip("en9", "  "), input: nil, attempt: nil, reply: nil, systemPrompt: nil
        )
        #expect(RefineStageBench.lostInRefinement(cs3) == ["fix", "merge"])
        #expect(RefineStageBench.gainedInRefinement(encs4) == ["王老师"])
        #expect(RefineStageBench.lostInRefinement(encs1).isEmpty)  // raw shipped: nothing lost

        let condition = RefineStageBench.ConditionResult(
            label: "Qwen3-ASR 1.7B, Automatic", clips: [cs3, encs1, encs4, silent]
        )
        let words = RefineStageBench.wordTable([condition])
        #expect(words.contains("| Qwen3-ASR 1.7B, Automatic | cs3 | bug | K | K | refined |"))
        #expect(words.contains("| Qwen3-ASR 1.7B, Automatic | cs3 | fix | K | D | refined |"))
        #expect(words.contains("| Qwen3-ASR 1.7B, Automatic | encs1 | 周五 | K | K | rawRejected |"))
        #expect(words.contains("| Qwen3-ASR 1.7B, Automatic | encs4 | 王老师 | D | K | refined |"))

        let clips = RefineStageBench.clipTable([condition])
        #expect(clips.contains(
            "| Qwen3-ASR 1.7B, Automatic | cs3 | refined | zh | fix, merge | \"\(Fixture.cs3Raw)\" | \"\(Fixture.cs3Refined)\" | \"\(Fixture.cs3Refined)\" |"
        ))
        // The guard's catch is visible: raw delivered, the model's translation beside it.
        #expect(clips.contains(
            "| Qwen3-ASR 1.7B, Automatic | encs1 | rawRejected | generic | — | \"\(Fixture.encs1Raw)\" | \"\(Fixture.encs1Raw)\" | \"\(Fixture.encs1Translated)\" |"
        ))
        #expect(clips.contains("| Qwen3-ASR 1.7B, Automatic | encs4 | refined | generic | gained: 王老师 |"))
        #expect(clips.contains("| Qwen3-ASR 1.7B, Automatic | en9 | not attempted | — | — | \"\" | \"\" | — |"))
    }

    @Test("A table cell cannot be split by a pipe in a transcript (F631)")
    func aPipeInATranscriptIsEscaped() {
        let piped = RefineStageBench.result(
            for: Fixture.clip("x1", "a | b"),
            input: RefineStageBench.RefinerInput(text: "a | b", languageCode: nil),
            attempt: RefineAttempt(text: "A | b.", outcome: .refined),
            reply: "A | b.", systemPrompt: DictationRefinePrompt.system(languageCode: nil)
        )
        let table = RefineStageBench.clipTable([.init(label: "E", clips: [piped])])
        #expect(table.contains(#"| E | x1 | refined | generic | — | "a \| b" | "A \| b." | "A \| b." |"#))
    }
}

// MARK: - The real run (opt-in)

/// The real-model half: the installed refine helper, driven the way the app drives it.
///
/// Disabled unless asked for, because each condition loads the multi-gigabyte refine model:
///
/// ```
/// Scripts/bench/dictation-ab.py --clips encs,cs --words --json /tmp/raw-auto.json
/// Scripts/bench/dictation-ab.py --clips encs,cs --words --language English --json /tmp/raw-en.json
/// WHISPERMEET_REFINE_BENCH=1 WHISPERMEET_REFINE_BENCH_RAW=/tmp/raw-auto.json:/tmp/raw-en.json \
///   swift test --disable-sandbox --no-parallel --filter RefineStageBenchTests
/// ```
///
/// (On a Command Line Tools Mac, add the framework flags AGENTS.md lists under Build commands.)
/// `WHISPERMEET_REFINE_BENCH_OUT=<path>` also writes the report to a file; it always goes to stderr.
/// Every engine in every raw file is one condition, and each condition gets a fresh helper, primed
/// as the app primes it. F589 did the same because a resident helper's reply depends on the
/// requests before it (F630). After a `rawTimeout` or `rawError` row the bench also starts a fresh
/// helper for the next row, because the app releases its helper after either one.
///
/// It asserts only that the run measured something: the port agrees with dictation-ab.py on the
/// raw text, and no row is `rawBusy` (the bench failed to wait) or `rawError` (the helper failed).
/// Which words refinement keeps is the result to read, not a threshold to pass.
@Suite("Refine-stage bench against the installed refine helper (F631, opt-in)")
struct RefineStageBenchTests {
    @Test(
        "Each raw dictation goes through DictationRefiner as the app sends it, one fresh refine helper per condition (F631)",
        .enabled(if: RefineStageBenchEnvironment.isRequested)
    )
    func refinesEachRawDictationAsTheAppDoes() async throws {
        let paths = RefineStageBenchEnvironment.rawPaths
        try #require(
            !paths.isEmpty,
            "Set WHISPERMEET_REFINE_BENCH_RAW to one or more `dictation-ab.py --json` files, separated by ':'."
        )
        try #require(
            RefineStageBenchEnvironment.refineRuntimeReady,
            "No refine runtime under \(SummarizerRuntime.managedDirectory().path)."
        )

        var conditions: [RefineStageBench.ConditionResult] = []
        for path in paths {
            let runs = try RefineStageBench.decodeRuns(from: Data(contentsOf: URL(fileURLWithPath: path)))
            for run in runs {
                let disagreements = RefineStageBench.rawVerdictDisagreements(in: run)
                #expect(
                    disagreements.isEmpty,
                    "This port and dictation-ab.py disagree on the raw text: \(disagreements.joined(separator: "; "))"
                )
                conditions.append(try await RefineStageBenchRun.refine(run))
            }
        }

        let report = RefineStageBenchRun.report(conditions, rawPaths: paths)
        FileHandle.standardError.write(Data((report + "\n").utf8))
        if let output = RefineStageBenchEnvironment.outputPath {
            try report.write(toFile: output, atomically: true, encoding: .utf8)
        }
        for condition in conditions {
            for clip in condition.clips {
                #expect(
                    clip.outcome != .rawBusy,
                    "\(condition.label) \(clip.clip): rawBusy means the bench did not wait for the previous request, so this row measured nothing."
                )
                #expect(
                    clip.outcome != .rawError,
                    "\(condition.label) \(clip.clip): the refine helper failed: \(clip.modelReply ?? "no reply")"
                )
            }
        }
    }
}

private enum RefineStageBenchEnvironment {
    private static var values: [String: String] { ProcessInfo.processInfo.environment }

    static var isRequested: Bool { values["WHISPERMEET_REFINE_BENCH"] == "1" }

    /// `dictation-ab.py --json` files, separated by ":" as PATH entries are.
    static var rawPaths: [String] {
        (values["WHISPERMEET_REFINE_BENCH_RAW"] ?? "")
            .split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }

    static var outputPath: String? {
        guard let path = values["WHISPERMEET_REFINE_BENCH_OUT"], !path.isEmpty else { return nil }
        return path
    }

    static var refineRuntimeReady: Bool {
        let files = FileManager.default
        return files.isExecutableFile(atPath: SummarizerRuntime.pythonExecutable().path)
            && files.fileExists(atPath: SummarizerRuntime.refineHelperScript().path)
            && files.fileExists(
                atPath: SummarizerRuntime.modelDirectory()
                    .appendingPathComponent("model.safetensors").path
            )
    }
}

private enum RefineStageBenchRun {
    /// One condition: a fresh helper, then every raw transcript in the file's order on that helper,
    /// as successive refined dictations reach one resident helper in the app.
    static func refine(_ run: RefineStageBench.RawRun) async throws -> RefineStageBench.ConditionResult {
        let engine = RecordingRefineEngine(base: ProductionRefineConstruction.engine())
        // The app's default budget sleep, passed explicitly: see `ProductionRefineConstruction.budgetSleep`.
        let refiner = DictationRefiner(engine: engine, sleep: ProductionRefineConstruction.budgetSleep)
        defer { refiner.shutdown() }
        // The app warms the refiner before a dictation can use it; warm-up sends the F203 prime.
        let warmed = await refiner.warmUp()
        try #require(warmed, "The refine helper did not warm up for \(RefineStageBench.conditionLabel(for: run)).")

        var clips: [RefineStageBench.ClipResult] = []
        for raw in run.clips {
            guard let input = RefineStageBench.refinerInput(for: raw) else {
                clips.append(RefineStageBench.result(
                    for: raw, input: nil, attempt: nil, reply: nil, systemPrompt: nil
                ))
                continue
            }
            let callsBefore = await engine.log.calls.count
            let attempt = await refiner.attempt(
                text: input.text, languageCode: input.languageCode, protectedTerms: []
            )
            // After a rawTimeout the refiner has answered, but its request is still generating. The
            // next dictation would then be rawBusy, and that row would measure the bench, not the model.
            // Waiting also records the reply the budget cut off.
            await engine.log.waitUntilIdle()
            if attempt.outcome == .rawTimeout || attempt.outcome == .rawError {
                // The app releases the helper after either outcome (DictationController), so its
                // next refined dictation reaches a fresh, primed helper. Do the same, so the next
                // row does not run on a request history the app never keeps (F630).
                await refiner.evict()
                let rewarmed = await refiner.warmUp()
                try #require(rewarmed, "The refine helper did not warm up again after \(raw.clip)'s \(attempt.outcome.rawValue).")
            }
            let cleared = try await refinerCleared(refiner)
            try #require(cleared, "The refiner still reported busy 5 s after its helper had replied.")

            let calls = await engine.log.calls
            let call = calls.count > callsBefore ? calls[callsBefore] : nil
            clips.append(RefineStageBench.result(
                for: raw, input: input, attempt: attempt,
                reply: call.map { $0.reply ?? "error: \($0.failure ?? "no detail")" },
                systemPrompt: call?.request.systemPrompt
            ))
        }
        // Wait for the child to exit before the next condition starts its own.
        await refiner.evict()
        return RefineStageBench.ConditionResult(label: RefineStageBench.conditionLabel(for: run), clips: clips)
    }

    /// `DictationRefiner` frees its busy flag in a task that runs just after the engine replies.
    /// Empty text probes that flag without reaching the engine: `.rawBusy` while it is set, then
    /// `.skipped`, because the policy never refines an empty transcript. The engine wait before
    /// this needs no clock; the 5 s bound here only covers that one hop.
    private static func refinerCleared(_ refiner: DictationRefiner) async throws -> Bool {
        for _ in 0..<1_000 {
            if await refiner.attempt(text: "", languageCode: nil).outcome != .rawBusy { return true }
            try await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    static func report(_ conditions: [RefineStageBench.ConditionResult], rawPaths: [String]) -> String {
        [
            "# Refine stage, per word (F631)",
            "",
            "- Refine helper: \(SummarizerRuntime.refineHelperScript().path)",
            "- Model: \(SummarizerRuntime.modelDirectory().path)",
            "- Raw transcripts: \(rawPaths.joined(separator: ", "))",
            "- One fresh helper per condition, warmed with the app's prime. protectedTerms: none,",
            "  because the bench never reads the user's vocabulary.",
            "",
            "## Per clip",
            "",
            RefineStageBench.clipTable(conditions),
            "",
            "## Per word (K = kept verbatim, D = dropped; dictation-ab.py's rule)",
            "",
            RefineStageBench.wordTable(conditions),
        ].joined(separator: "\n")
    }
}

/// The production engine with each request and reply recorded. It only forwards, so the refiner
/// runs its real path against the real helper. The record is what lets a `rawRejected` row show
/// the reply the guard refused.
private struct RecordingRefineEngine: DictationRefineEngine {
    let base: WarmRefineEngine
    let log = RefineCallLog()

    func warmUp() async throws { try await base.warmUp() }

    func refine(_ request: RefineRequest) async throws -> String {
        let index = await log.began(request)
        do {
            let reply = try await base.refine(request)
            await log.ended(index, reply: reply, failure: nil)
            return reply
        } catch {
            await log.ended(index, reply: nil, failure: String(describing: error))
            throw error
        }
    }

    func shutdown() { base.shutdown() }

    func evict() async { await base.evict() }
}

private actor RefineCallLog {
    struct Call: Sendable {
        let request: RefineRequest
        var reply: String?
        var failure: String?
    }

    private(set) var calls: [Call] = []
    private var inFlight = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    func began(_ request: RefineRequest) -> Int {
        inFlight += 1
        calls.append(Call(request: request, reply: nil, failure: nil))
        return calls.count - 1
    }

    func ended(_ index: Int, reply: String?, failure: String?) {
        calls[index].reply = reply
        calls[index].failure = failure
        inFlight -= 1
        guard inFlight == 0 else { return }
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// Returns once no request is with the helper. It resumes when the reply arrives, not on a timer.
    func waitUntilIdle() async {
        guard inFlight > 0 else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }
}
