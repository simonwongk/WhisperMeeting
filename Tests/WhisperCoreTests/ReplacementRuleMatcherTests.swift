import Foundation
import Testing
@testable import WhisperCore

// F179 — exact user-defined replacement rules (heard → preferred) become reviewable corrections that
// flow through the same F82/F65 review + apply path. Exact substring match, one per segment, and the
// audio is never touched (corrections apply to segment text only).

private func seg(_ text: String) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: 0, end: 1, text: text)
}

@Test("A replacement rule proposes a correction only in segments that contain the heard phrase (F179)")
func proposesOnlyWhereHeardOccurs() {
    let segments = [
        seg("We use Sequoia for infra."),
        seg("No mention here."),
        seg("Ask Sequoia about pricing."),
    ]
    let corrections = ReplacementRuleMatcher.corrections(
        rules: [ReplacementRule(heard: "Sequoia", preferred: "Sequoya")],
        segments: segments
    )
    #expect(corrections == [
        GlossaryCorrection(segmentIndex: 0, from: "Sequoia", to: "Sequoya"),
        GlossaryCorrection(segmentIndex: 2, from: "Sequoia", to: "Sequoya"),
    ])
}

@Test("A no-op or empty rule proposes nothing (F179)")
func skipsNoOpRules() {
    let segments = [seg("Sequoia and Acme.")]
    #expect(ReplacementRuleMatcher.corrections(
        rules: [ReplacementRule(heard: "Sequoia", preferred: "Sequoia")], segments: segments
    ).isEmpty)
    #expect(ReplacementRuleMatcher.corrections(
        rules: [ReplacementRule(heard: "", preferred: "Acme")], segments: segments
    ).isEmpty)
}

@Test("Applying a rule's corrections changes only the heard phrase, and never the audio path (F179)")
func applyReplacesExactly() {
    let segments = [seg("We use Sequoia for infra."), seg("Nothing here.")]
    let corrections = ReplacementRuleMatcher.corrections(
        rules: [ReplacementRule(heard: "Sequoia", preferred: "Sequoya")],
        segments: segments
    )
    let applied = GlossaryCorrector.apply(corrections, to: segments)
    #expect(applied[0].text == "We use Sequoya for infra.")
    #expect(applied[1].text == "Nothing here.")
}

// MARK: - F444 (a rule's own `preferred` swallows `heard`, and word-boundary matching)

@Test("A rule is not proposed in a segment where `heard` occurs only inside `preferred` (F444)")
func skipsSegmentsWhereHeardOnlyOccursInsidePreferred() {
    // The ticket's own scenario: "Jonathan will present." already reads correctly — the only "Jon"
    // in it is the one inside "Jonathan" — so no correction should be proposed there at all.
    let onlyCorrect = [seg("Jonathan will present.")]
    #expect(ReplacementRuleMatcher.corrections(
        rules: [ReplacementRule(heard: "Jon", preferred: "Jonathan")], segments: onlyCorrect
    ).isEmpty)

    // A line with BOTH the already-correct word and a genuine mis-hearing proposes exactly one
    // correction — for the standalone "Jon", not the "Jon" fragment inside "Jonathan".
    let mixed = [seg("Thanks Jonathan, and Jon agrees.")]
    let corrections = ReplacementRuleMatcher.corrections(
        rules: [ReplacementRule(heard: "Jon", preferred: "Jonathan")], segments: mixed
    )
    #expect(corrections == [GlossaryCorrection(segmentIndex: 0, from: "Jon", to: "Jonathan")])

    // Applying it must reach the standalone "Jon", not the first substring match in the line (which
    // is the "Jon" inside "Jonathan" — replacing that one would corrupt an already-correct word).
    let applied = GlossaryCorrector.apply(corrections, to: mixed)
    #expect(applied[0].text == "Thanks Jonathan, and Jonathan agrees.")
}

@Test("Word-boundary matching does not clip an unrelated word that merely contains `heard` (F444)")
func doesNotClipAnUnrelatedWord() {
    // "Jon" is a plain substring of "Jones" too, but "Jones" has nothing to do with this rule.
    let segments = [seg("Jones will present."), seg("Jon will present.")]
    let corrections = ReplacementRuleMatcher.corrections(
        rules: [ReplacementRule(heard: "Jon", preferred: "Jonathan")], segments: segments
    )
    #expect(corrections == [GlossaryCorrection(segmentIndex: 1, from: "Jon", to: "Jonathan")])

    let applied = GlossaryCorrector.apply(corrections, to: segments)
    #expect(applied[0].text == "Jones will present.", "an unrelated word must survive untouched")
    #expect(applied[1].text == "Jonathan will present.")
}

@Test("A Latin `heard` glued directly to CJK text with no space still counts as a whole word (F444)")
func latinHeardIsWholeEvenGluedToCJK() {
    // Common in Chinese meetings: an English term with no surrounding space. The classic `\b` regex
    // boundary does NOT fire here (Han ideographs count as word characters to ICU), so this pins
    // that the rules matcher's own boundary check — not `\b` — is what is actually running.
    let segments = [seg("我们在用Kestrel做测试，然后Kestrel换成了新版本。")]
    let corrections = ReplacementRuleMatcher.corrections(
        rules: [ReplacementRule(heard: "Kestrel", preferred: "Falcon")], segments: segments
    )
    #expect(corrections == [GlossaryCorrection(segmentIndex: 0, from: "Kestrel", to: "Falcon")])
}

@Test("A CJK rule is not proposed where `heard` occurs only inside `preferred` (F444, CJK has no word boundary)")
func skipsCJKSegmentsWhereHeardOnlyOccursInsidePreferred() {
    // CJK has no space between words, so this case leans entirely on the "not covered by preferred"
    // rule rather than a whole-token check (which is deliberately not enforced for CJK, per
    // ReplacementBoundary's documentation).
    let onlyCorrect = [seg("现在网元件已经就绪。")]
    #expect(ReplacementRuleMatcher.corrections(
        rules: [ReplacementRule(heard: "网元", preferred: "网元件")], segments: onlyCorrect
    ).isEmpty)

    let mixed = [seg("现在网元件已经就绪，网元还没配置。")]
    let corrections = ReplacementRuleMatcher.corrections(
        rules: [ReplacementRule(heard: "网元", preferred: "网元件")], segments: mixed
    )
    #expect(corrections == [GlossaryCorrection(segmentIndex: 0, from: "网元", to: "网元件")])
    let applied = GlossaryCorrector.apply(corrections, to: mixed)
    #expect(applied[0].text == "现在网元件已经就绪，网元件还没配置。")
}
