import Foundation
import Testing
@testable import WhisperCore

// F82 — the glossary corrector could propose corrections but had no `apply`. It must replace the
// reviewed `from` phrase with the term in ONLY the correction's target segment, leaving identical
// text in other segments alone.
@Test("GlossaryCorrector.apply replaces the from-phrase with the term in only the target segment (F82)")
func glossaryApplyReplacesOnlyTargetSegment() {
    let segments = [
        TranscriptSegment(speaker: nil, start: 0, end: 1, text: "we deployed cooper netties today"),
        TranscriptSegment(speaker: nil, start: 1, end: 2, text: "cooper netties again"),
    ]
    let corrections = [GlossaryCorrection(segmentIndex: 0, from: "cooper netties", to: "Kubernetes")]
    let result = GlossaryCorrector.apply(corrections, to: segments)
    #expect(result[0].text == "we deployed Kubernetes today")
    #expect(result[1].text == "cooper netties again")   // only the targeted index changes
}

// F939 — `apply` resolved each ticked row against the text the rows before it had already changed.
// Two rows for one occurrence, both ticked, so changed the reviewed occurrence and then the next one
// nobody reviewed; and a row whose text an earlier row wrote ("Jon → Jonathan", then "Jonathan →
// jon") changed the word just written instead of its own. Every row now finds its place in the text
// as it was reviewed, and a second row for a place already taken changes nothing.

private func line(_ text: String) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: 0, end: 1, text: text)
}

@Test("Two rules for one heard word give one row, and ticking every row changes only the reviewed occurrence (F939)")
func twoRulesForOneHeardWordChangeOnlyTheReviewedOccurrence() {
    let rules = [ReplacementRule(heard: "jon", preferred: "Jonathan"), ReplacementRule(heard: "jon", preferred: "John")]
    let segments = [line("jon met jon")]
    let proposed = ReplacementRuleMatcher.corrections(rules: rules, segments: segments)
    #expect(proposed == [GlossaryCorrection(segmentIndex: 0, from: "jon", to: "Jonathan")])
    #expect(GlossaryCorrector.apply(proposed, to: segments)[0].text == "Jonathan met jon")
}

@Test("Two rows for one occurrence from the local model or the vocabulary change it once, never a second occurrence (F939)")
func twoRowsForOneOccurrenceChangeItOnce() {
    // The local model's two readings of one word: each becomes a row for the segment's first "jon".
    let segments = [line("jon met jon")]
    let model = TranscriptCorrection.glossaryCorrections(
        from: [TranscriptCorrection(from: "jon", to: "John"), TranscriptCorrection(from: "jon", to: "Jonathan")],
        segments: segments
    )
    #expect(model == [
        GlossaryCorrection(segmentIndex: 0, from: "jon", to: "John"),
        GlossaryCorrection(segmentIndex: 0, from: "jon", to: "Jonathan"),
    ])
    #expect(GlossaryCorrector.apply(model, to: segments)[0].text == "John met jon")
    // Two vocabulary terms near one mishearing: both rows are for the first "Kestrol".
    let release = [line("the Kestrol build and the Kestrol release")]
    let vocabulary = GlossaryCorrector.corrections(vocabulary: ["Kestrel", "Kestrell"], segments: release)
    #expect(vocabulary == [
        GlossaryCorrection(segmentIndex: 0, from: "Kestrol", to: "Kestrel"),
        GlossaryCorrection(segmentIndex: 0, from: "Kestrol", to: "Kestrell"),
    ])
    #expect(GlossaryCorrector.apply(vocabulary, to: release)[0].text == "the Kestrel build and the Kestrol release")
}

@Test("A row whose text an earlier row writes still changes its own place, not the word just written (F939)")
func chainedRowsEachChangeTheirOwnPlace() {
    let rules = [ReplacementRule(heard: "Jon", preferred: "Jonathan"), ReplacementRule(heard: "Jonathan", preferred: "jon")]
    let segments = [line("Jon met Jonathan.")]
    let proposed = ReplacementRuleMatcher.corrections(rules: rules, segments: segments)
    #expect(proposed == [
        GlossaryCorrection(segmentIndex: 0, from: "Jon", to: "Jonathan"),
        GlossaryCorrection(segmentIndex: 0, from: "Jonathan", to: "jon"),
    ])
    // Each row changes the occurrence its sentence shows, in whichever order the rows arrive.
    #expect(GlossaryCorrector.apply(proposed, to: segments)[0].text == "Jonathan met jon.")
    #expect(GlossaryCorrector.apply(Array(proposed.reversed()), to: segments)[0].text == "Jonathan met jon.")
    // Rows in different segments, and rows at different places in one segment, all still apply.
    let two = [line("cooper netties and Kestrol"), line("Kestrol again")]
    let rows = [
        GlossaryCorrection(segmentIndex: 0, from: "Kestrol", to: "Kestrel"),
        GlossaryCorrection(segmentIndex: 0, from: "cooper netties", to: "Kubernetes"),
        GlossaryCorrection(segmentIndex: 1, from: "Kestrol", to: "Kestrel"),
    ]
    #expect(GlossaryCorrector.apply(rows, to: two).map(\.text) == ["Kubernetes and Kestrel", "Kestrel again"])
}
