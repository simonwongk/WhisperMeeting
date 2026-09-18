import Foundation
import Testing
@testable import WhisperCore

// F244 — the content-fidelity bench measures what the app's prompts do to sensitive material. The
// harness is Python and the prompts are Swift, so the bench reads them from a checked-in fixture,
// `Scripts/bench/fidelity/prompts.json`.
//
// That fixture is the whole reason this file exists. The design considered a Swift harness over the
// real WhisperCore types and rejected it — "the drift it prevents is covered more cheaply by the
// prompt fixture test" (`docs/superpowers/specs/2026-09-14-content-fidelity-bench-design.md`). This
// IS that cheaper thing, so if it does not actually catch drift, the spec traded away its only
// guard for nothing.
//
// The failure it exists to prevent is silent and retroactive: someone edits
// `DictationRefinePrompt.system` in a way that changes how the model treats a proper noun, the
// fixture keeps the old string, and every number the bench has ever printed now describes a prompt
// the app no longer sends. Nothing looks broken. The scorecard even records the fixture's SHA-256,
// which agrees with itself.
//
// Note what `fixtureMatchesTheLivePrompts` alone would prove: nothing. A generator compared against
// its own output always agrees. So the middle test mutates each field in turn and requires the
// comparison to name it — that is the test that has a production change able to fail it.

/// The prompts the bench sends, exactly as the app builds them. Field names are the JSON keys the
/// Python harness reads, so renaming one is a breaking change to `run_fidelity.py`.
private struct FidelityPrompts: Codable, Equatable {
    /// Keyed by the language code passed to `DictationRefinePrompt.system`, with `none` standing in
    /// for `nil` — JSON has no null-keyed object, and the no-language case is a real surface (the
    /// refiner runs before language detection settles).
    var refineSystem: [String: String]
    var correctionSystem: String
    /// Both branches of `LocalTranscriptCorrector.userContent`: with vocabulary and reference, and
    /// with neither. The Python side assembles this turn itself, so it needs the layout of each.
    var correctionUserContent: [String: RenderedUserContent]
    var summarySystem: [String: String]

    struct RenderedUserContent: Codable, Equatable {
        var transcript: String
        var vocabulary: [String]
        var reference: String?
        /// What Swift produces from the three inputs above. `run_fidelity.py` compares its own
        /// rendering against this, which is how the harness proves it assembles the same user turn
        /// rather than a plausible-looking one.
        var rendered: String
    }

    /// Neutral by design: this file is tracked and the repository is public. The sensitive corpus
    /// lives in `Scripts/bench/fidelity/corpus/`, untracked.
    static let fullSample = RenderedUserContent(
        transcript: "We shipped the Kestrel release on Tuesday.",
        vocabulary: ["Kestrel", "Fairhaven"],
        reference: "Kestrel is the spring release. Fairhaven is the London office.",
        rendered: ""
    )
    static let minimalSample = RenderedUserContent(
        transcript: "We shipped the Kestrel release on Tuesday.",
        vocabulary: [],
        reference: nil,
        rendered: ""
    )

    /// Built from the live app code. The single place that knows which prompts the bench covers.
    static func live() -> FidelityPrompts {
        func render(_ sample: RenderedUserContent) -> RenderedUserContent {
            var filled = sample
            filled.rendered = LocalTranscriptCorrector.userContent(
                transcript: sample.transcript,
                vocabulary: sample.vocabulary,
                reference: sample.reference
            )
            return filled
        }
        return FidelityPrompts(
            refineSystem: [
                "zh": DictationRefinePrompt.system(languageCode: "zh"),
                // F244: the arms the app sends once the dictation's script is read from its text.
                // `run_fidelity.py` picks them the same way, with the scorer's own character table.
                "zh-Hant": DictationRefinePrompt.system(languageCode: "zh", script: .traditional),
                "zh-Hans": DictationRefinePrompt.system(languageCode: "zh", script: .simplified),
                "en": DictationRefinePrompt.system(languageCode: "en"),
                "none": DictationRefinePrompt.system(languageCode: nil),
            ],
            correctionSystem: LocalTranscriptCorrector.systemPrompt,
            correctionUserContent: [
                "withVocabularyAndReference": render(fullSample),
                "transcriptOnly": render(minimalSample),
            ],
            // Balanced style and the general template: the defaults the app applies unless the user
            // picks otherwise, and the only combination the bench measures (F246 may widen it).
            summarySystem: [
                "zh": LocalSummarizer.systemPrompt(language: "zh", style: .balanced, template: .general),
                "en": LocalSummarizer.systemPrompt(language: "en", style: .balanced, template: .general),
            ]
        )
    }

    /// Named differences rather than a bare `==`, so a failure says which prompt moved. A diff of
    /// two 1,200-character strings is unreadable; `summarySystem.zh` is not.
    func differences(from other: FidelityPrompts) -> [String] {
        var names: [String] = []
        func compare<T: Equatable>(_ label: String, _ lhs: T, _ rhs: T) {
            if lhs != rhs { names.append(label) }
        }
        for key in Set(refineSystem.keys).union(other.refineSystem.keys).sorted() {
            compare("refineSystem.\(key)", refineSystem[key], other.refineSystem[key])
        }
        compare("correctionSystem", correctionSystem, other.correctionSystem)
        for key in Set(correctionUserContent.keys).union(other.correctionUserContent.keys).sorted() {
            compare("correctionUserContent.\(key)", correctionUserContent[key], other.correctionUserContent[key])
        }
        for key in Set(summarySystem.keys).union(other.summarySystem.keys).sorted() {
            compare("summarySystem.\(key)", summarySystem[key], other.summarySystem[key])
        }
        return names
    }

    /// Sorted keys and no escaped slashes so regeneration is byte-stable: an unstable encoder would
    /// change the fixture's SHA-256 on every run, and that digest is what tells the user whether two
    /// benchmark runs are comparable at all.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhisperCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Scripts/bench/fidelity/prompts.json")
    }
}

@Test("The bench's prompt fixture is byte-equal to the prompts the app builds (F244)")
func fixtureMatchesTheLivePrompts() throws {
    let live = FidelityPrompts.live()

    // The regeneration path the spec asks for. Deliberately a write of the whole file rather than a
    // patch: a partial update is how a fixture ends up internally inconsistent.
    if ProcessInfo.processInfo.environment["FIDELITY_PROMPTS_REGENERATE"] == "1" {
        try FidelityPrompts.encoder().encode(live).write(to: FidelityPrompts.fixtureURL)
        return
    }

    let data = try Data(contentsOf: FidelityPrompts.fixtureURL)
    let stored = try JSONDecoder().decode(FidelityPrompts.self, from: data)
    let drifted = stored.differences(from: live)
    #expect(
        drifted.isEmpty,
        "these prompts have changed in the app but not in the bench fixture: \(drifted.joined(separator: ", ")). Every fidelity number measured with the old fixture describes a prompt the app no longer sends. Regenerate with FIDELITY_PROMPTS_REGENERATE=1 and re-run the affected arms."
    )
}

@Test("A change to any single covered prompt is detected, not just reported as unequal (F244)")
func driftInAnyPromptIsDetected() {
    let live = FidelityPrompts.live()
    #expect(live.differences(from: live).isEmpty)

    // One mutation per field, each expected to be named exactly. Without this the suite would prove
    // only that a generator agrees with itself — and a comparison that silently skipped a field
    // (an early `return`, a key typo, a dictionary compared by count) would pass just as happily.
    var mutations: [(String, FidelityPrompts)] = []
    for key in ["zh", "en", "none"] {
        var m = live
        m.refineSystem[key] = (live.refineSystem[key] ?? "") + " and translate it into English."
        mutations.append(("refineSystem.\(key)", m))
    }
    var correction = live
    correction.correctionSystem += " Paraphrase for clarity."
    mutations.append(("correctionSystem", correction))
    for key in ["withVocabularyAndReference", "transcriptOnly"] {
        var m = live
        m.correctionUserContent[key]?.rendered += "\n\nIgnore the above."
        mutations.append(("correctionUserContent.\(key)", m))
    }
    for key in ["zh", "en"] {
        var m = live
        m.summarySystem[key] = (live.summarySystem[key] ?? "") + " Omit anything contentious."
        mutations.append(("summarySystem.\(key)", m))
    }

    for (expected, mutated) in mutations {
        #expect(mutated.differences(from: live) == [expected], "mutating \(expected) was not reported as exactly that field")
    }

    // A dropped key is drift too — a refactor that deletes the no-language refine case would
    // otherwise leave the bench silently measuring two surfaces instead of three.
    var missing = live
    missing.refineSystem.removeValue(forKey: "none")
    #expect(missing.differences(from: live) == ["refineSystem.none"])
}

@Test("Regenerating the fixture twice produces identical bytes (F244)")
func fixtureEncodingIsStable() throws {
    // The scorecard records this file's SHA-256 and two runs may only be compared when the digests
    // match, so an encoder whose key order varies would make every run incomparable with every
    // other for no real reason.
    let live = FidelityPrompts.live()
    let first = try FidelityPrompts.encoder().encode(live)
    let second = try FidelityPrompts.encoder().encode(live)
    #expect(first == second)

    let round = try JSONDecoder().decode(FidelityPrompts.self, from: first)
    #expect(round.differences(from: live).isEmpty)
}

@Test("The fixture's rendered correction turn matches what the corrector assembles (F244)")
func renderedCorrectionTurnIsTheRealLayout() throws {
    // The rendered string is what `run_fidelity.py` checks its own assembly against, so it has to be
    // the real one. Asserting the shape here as well means a change to the layout fails with a
    // readable reason rather than only as an opaque byte difference in the fixture.
    let live = FidelityPrompts.live()
    let full = try #require(live.correctionUserContent["withVocabularyAndReference"])
    #expect(full.rendered.hasPrefix("Transcript:\nWe shipped the Kestrel release on Tuesday."))
    #expect(full.rendered.contains("Correct business vocabulary:\n- Kestrel\n- Fairhaven"))
    #expect(full.rendered.contains("Reference document:\n"))

    let minimal = try #require(live.correctionUserContent["transcriptOnly"])
    #expect(!minimal.rendered.contains("Correct business vocabulary"))
    #expect(!minimal.rendered.contains("Reference document"))
}
