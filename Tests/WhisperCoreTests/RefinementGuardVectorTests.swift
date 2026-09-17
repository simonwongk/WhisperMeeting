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

@Test("A Traditional-to-Simplified rewrite passes the guard and would be pasted (F245)")
func scriptConversionIsNotCaughtByTheGuard() throws {
    // The finding, asserted rather than described. This is real output from the installed model on
    // neutral business content, and the guard accepts it — so a user dictating in Traditional
    // Chinese has their text replaced with Simplified, silently, today.
    //
    // Two checks are needed, not one. That the guard accepts it is the user-visible fact; that
    // `dominant` reports the same script for both is *why*, and asserting only the first would
    // leave the next reader to guess whether the cause was the length bound instead.
    let vector = try #require(try GuardVectors.load().vectors.first { $0.lang == "zh" })

    let accepted = DictationRefinePolicy.acceptedOutput(vector.output, input: vector.input)
    #expect(accepted != nil, "if this now rejects, F245's guard has landed — update the fixture")

    #expect(TranscriptLanguage.dominant(of: vector.input) == .chinese)
    #expect(TranscriptLanguage.dominant(of: vector.output) == .chinese)

    // And the conversion is real, not an artefact of how the fixture was written.
    #expect(vector.input.contains("倫敦辦公室"))
    #expect(vector.output.contains("伦敦办公室"))
}
