import Foundation
import Testing
@testable import WhisperCore

// F291 / F245 — what the refinement guard does with real model output.
//
// F244's pre-registered rule for this surface is that a model fails when a harmful alteration
// "passes the current guard and would be pasted". The bench records what the model returned; only
// `DictationRefinePolicy.acceptedOutput` decides whether the user ever sees it, and an alteration
// the guard rejects costs nothing because the raw transcript ships instead.
//
// The design proposed porting the guard to Python so the harness could answer this itself. F291
// argues against that and this file is the alternative: real outputs in a tracked fixture, the real
// guard as the oracle. The reason is specific rather than general — the script drift below exists
// *because* `TranscriptLanguage.dominant` cannot distinguish Traditional from Simplified, so a
// useful port would have to reproduce that limitation exactly, and any reasonable Python author
// would "fix" it and then report the opposite of the truth.
//
// The fixture is tracked, so this runs in CI where `Scripts/bench/fidelity/results/` does not exist.
// `expected` records what the guard *does*, not what it should do: a vector flipping is a change in
// shipped behaviour and has to be a deliberate edit here.

private struct GuardVectors: Decodable {
    struct Vector: Decodable {
        let id: String
        let lang: String
        let input: String
        let output: String
        let expected: String
        let note: String
    }
    let vectors: [Vector]

    static func load() throws -> GuardVectors {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/refinement-guard-vectors.json")
        return try JSONDecoder().decode(GuardVectors.self, from: try Data(contentsOf: url))
    }
}

@Test("The refinement guard's verdict on real model output is what the fixture records (F291)")
func refinementGuardVerdictsMatchTheFixture() throws {
    let loaded = try GuardVectors.load()
    #expect(!loaded.vectors.isEmpty)

    for vector in loaded.vectors {
        let accepted = DictationRefinePolicy.acceptedOutput(vector.output, input: vector.input)
        let verdict = accepted == nil ? "rejected" : "accepted"
        #expect(
            verdict == vector.expected,
            "\(vector.id): the guard now \(verdict) this output where the fixture records \(vector.expected). \(vector.note)"
        )
    }
}

@Test("A Traditional-to-Simplified rewrite is refused, and the old tripwire still cannot see it (F245)")
func scriptConversionIsRefusedByTheNewCheck() throws {
    // This test used to assert the opposite, and was named for it: the guard *accepted* this real
    // output from the installed model, so a user dictating in Traditional Chinese had their words
    // replaced with Simplified. It is inverted here because F245's check landed — which is what
    // the old assertion's comment asked for ("if this now rejects, F245's guard has landed").
    //
    // The two `dominant` assertions are kept deliberately, now that they no longer explain a
    // defect. They pin the *cause*: the language tripwire still reports the same script for both
    // sides, so it is not what refuses this — `ScriptDrift` is. Deleting them would leave a future
    // reader to assume the language check had been fixed, and reach for the wrong lever when it
    // next misses something.
    let vector = try #require(try GuardVectors.load().vectors.first { $0.lang == "zh" })

    #expect(
        DictationRefinePolicy.acceptedOutput(vector.output, input: vector.input) == nil,
        "the raw Traditional transcript must ship instead"
    )

    #expect(TranscriptLanguage.dominant(of: vector.input) == .chinese)
    #expect(TranscriptLanguage.dominant(of: vector.output) == .chinese)
    #expect(ScriptDrift.isSimplifyingConversion(source: vector.input, output: vector.output))

    // And the conversion is real, not an artefact of how the fixture was written.
    #expect(vector.input.contains("倫敦辦公室"))
    #expect(vector.output.contains("伦敦办公室"))
}

// MARK: - Emitting the verdicts for a whole bench run (F291)

// The report needs the guard's verdict per record, and the alternative to a Python port is to have
// the shipped guard write them out. `REFINE_GUARD_VERDICTS=<results dir>` does that, following the
// same env-var pattern as `FIDELITY_PROMPTS_REGENERATE` in the prompt fixture — so no second
// `Package.swift` executable target is needed, which is the cost the design objected to.
//
// The pure mapping is tested in memory below, so these tests do real work with or without the
// variable set. Only the file read and write are conditional.

private struct RefinementRun: Decodable {
    let id: String
    let input: Input
    let output: Output?
    let error: String?

    struct Input: Decodable { let text: String }
    struct Output: Decodable { let text: String? }
    /// The corpus item's protected terms, written by `run_fidelity.py` beside each record (F245).
    /// Optional so a run recorded before the field existed still decodes; it is then judged
    /// without the term guard, which is what the app did at the time.
    let protectedTerms: [String]?

    private enum CodingKeys: String, CodingKey {
        case id, input, output, error
        case protectedTerms = "protected_terms"
    }
}

private struct GuardVerdict: Encodable, Equatable {
    /// `accepted`, `rejected`, or `error` — three states, not two. An errored record produced no
    /// output for the guard to judge, and calling that `rejected` would report the guard as having
    /// protected the user from something that never reached it.
    let status: String
    /// What the user would actually receive: the guard's *cleaned* candidate, not the raw model
    /// text. The report scores the raw output; this is here so a reviewer can see the difference.
    let delivered: String?
}

private func guardVerdicts(for records: [RefinementRun]) -> [String: GuardVerdict] {
    var verdicts: [String: GuardVerdict] = [:]
    for record in records {
        guard record.error == nil, let text = record.output?.text, !text.isEmpty else {
            verdicts[record.id] = GuardVerdict(status: "error", delivered: nil)
            continue
        }
        if let delivered = DictationRefinePolicy.acceptedOutput(
            text, input: record.input.text, protectedTerms: record.protectedTerms ?? []
        ) {
            verdicts[record.id] = GuardVerdict(status: "accepted", delivered: delivered)
        } else {
            verdicts[record.id] = GuardVerdict(status: "rejected", delivered: nil)
        }
    }
    return verdicts
}

private func decodeRuns(_ jsonLines: String) throws -> [RefinementRun] {
    let decoder = JSONDecoder()
    return try jsonLines
        .split(separator: "\n", omittingEmptySubsequences: true)
        .compactMap { line -> RefinementRun? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
            // A run killed mid-write leaves a partial final line; skipping it must not cost the
            // records before it.
            return try? decoder.decode(RefinementRun.self, from: data)
        }
}

@Test("An accepted output records what the user would actually receive (F291)")
func guardVerdictForAnAcceptedOutput() throws {
    let runs = try decodeRuns("""
    {"id":"a","input":{"text":"um so we shipped the Kestrel release on tuesday you know"},"output":{"text":"\\"We shipped the Kestrel release on Tuesday.\\""},"error":null}
    """)
    let verdict = try #require(guardVerdicts(for: runs)["a"])
    #expect(verdict.status == "accepted")
    // The wrapping quotes are the guard's to strip, and `delivered` is post-guard, so a reviewer
    // comparing it against the raw output sees exactly what the app changed.
    #expect(verdict.delivered == "We shipped the Kestrel release on Tuesday.")
}

@Test("An output the guard refuses is recorded rejected, with nothing delivered (F291)")
func guardVerdictForARejectedOutput() throws {
    let runs = try decodeRuns("""
    {"id":"b","input":{"text":"um so we shipped the Kestrel release on tuesday and the Fairhaven office picked it up"},"output":{"text":"ok"},"error":null}
    """)
    let verdict = try #require(guardVerdicts(for: runs)["b"])
    #expect(verdict.status == "rejected")
    #expect(verdict.delivered == nil)
}

@Test("An errored record is `error`, not `rejected` (F291)")
func guardVerdictForAnErroredRecord() throws {
    // Three states rather than two: calling this `rejected` would credit the guard with stopping
    // something it never saw, and the report's own accounting rule is that an errored item is
    // unmeasured rather than either outcome.
    let runs = try decodeRuns("""
    {"id":"c","input":{"text":"anything"},"output":null,"error":"model died"}
    {"id":"d","input":{"text":"anything"},"output":{"text":""},"error":null}
    """)
    let verdicts = guardVerdicts(for: runs)
    #expect(verdicts["c"]?.status == "error")
    #expect(verdicts["d"]?.status == "error")
}

@Test("The emitter applies the protected-term guard to a record that carries terms (F245)")
func emitterAppliesTheTermGuardToARecord() throws {
    // F245: the record's protected terms are the corpus item's; a rename of one is rejected by
    // the same guard the app runs, so the bench's "Pasted" column can see the new refusal.
    let runs = try decodeRuns("""
    {"id":"t","input":{"text":"um the Kestrel release ships tuesday"},"output":{"text":"The Kestral release ships Tuesday."},"error":null,"protected_terms":["Kestrel"]}
    {"id":"u","input":{"text":"um the Kestrel release ships tuesday"},"output":{"text":"The Kestral release ships Tuesday."},"error":null}
    """)
    let verdicts = guardVerdicts(for: runs)
    #expect(verdicts["t"]?.status == "rejected")
    #expect(verdicts["u"]?.status == "accepted", "without a term list the guard behaves as before")
}

@Test("The emitter writes verdicts beside a run's records when asked (F291)")
func guardVerdictsAreEmittedForARun() throws {
    guard let directory = ProcessInfo.processInfo.environment["REFINE_GUARD_VERDICTS"] else {
        // Nothing to emit. The mapping above is already covered in memory, so this is a real
        // no-op rather than an untested path.
        return
    }
    let runDirectory = URL(fileURLWithPath: directory)
    let records = try String(
        contentsOf: runDirectory.appendingPathComponent("refinement.jsonl"), encoding: .utf8
    )
    let verdicts = guardVerdicts(for: try decodeRuns(records))
    #expect(!verdicts.isEmpty, "no refinement records under \(directory)")

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    struct Payload: Encodable {
        let generator: String
        let verdicts: [String: GuardVerdict]
    }
    let payload = Payload(
        generator: "RefinementGuardVectorTests.swift via DictationRefinePolicy.acceptedOutput",
        verdicts: verdicts
    )
    try encoder.encode(payload).write(
        to: runDirectory.appendingPathComponent("guard-verdicts.json")
    )
}

@Test("The guard stops a translation AND a script conversion, through the emitter (F291, F245)")
func bothWritingSystemCrossingsAreRejected() throws {
    // F291's verification asks that a vector the guard rejects be reported rejected, and
    // `DictationRefineGuardrailTests.rejectsTranslation` supplies the natural one. Pairing it with
    // the script conversion is what makes it worth asserting here rather than only there: the two
    // are the same *kind* of change — the model returned the meaning in a different writing system
    // than the user spoke — and the guard treats them oppositely.
    //
    // It was not an oversight in the guard so much as a limit of what it could see.
    // `TranscriptLanguage.dominant` answers "which language", and Traditional and Simplified are
    // one language — so the tripwire caught the crossing it could detect and was blind to the one
    // it could not, and a reader of either test alone would not have noticed the gap between them.
    // `ScriptDrift` closes it (F245); this test is kept because the pairing is what made the gap
    // visible in the first place, and it is now what keeps both halves honest together.
    let runs = try decodeRuns("""
    {"id":"translation","input":{"text":"我们明天九点开会好不好"},"output":{"text":"We meet tomorrow at nine."},"error":null}
    {"id":"script","input":{"text":"那個 呃 我們星期二把 Kestrel 版本出貨了 然後 嗯 倫敦辦公室星期三才收到"},"output":{"text":"那个我们星期二把 Kestrel 版本出货了 然后伦敦办公室星期三才收到"},"error":null}
    {"id":"length","input":{"text":"please send the report tomorrow morning"},"output":{"text":"Sent."},"error":null}
    """)
    let verdicts = guardVerdicts(for: runs)

    #expect(verdicts["translation"]?.status == "rejected")
    #expect(verdicts["length"]?.status == "rejected")
    // Was `accepted`, and that asymmetry was the finding. Both crossings are refused now.
    #expect(verdicts["script"]?.status == "rejected")
    #expect(verdicts["script"]?.delivered == nil, "a rejected output delivers nothing")
}
