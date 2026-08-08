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
