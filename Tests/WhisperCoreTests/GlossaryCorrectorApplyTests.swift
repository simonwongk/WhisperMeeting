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

@Test("A row carrying the line it was proposed on applies only while its line still reads so, and shows that line's sentence (F971)")
func aRowAppliesOnlyToTheLineItWasProposedOn() {
    let rows = [
        GlossaryCorrection(segmentIndex: 0, from: "Jon", to: "Jonathan", characterOffset: 13, proposedLine: "Sam and Jon. Jon left."),
        GlossaryCorrection(segmentIndex: 1, from: "Kestrol", to: "Kestrel", proposedLine: "the Kestrol build"),
    ]
    // Line 0 changed after the rows were proposed; line 1 did not.
    let changed = [line("Samantha and Jon. Jon left."), line("the Kestrol build")]
    #expect(GlossaryCorrector.apply(rows, to: changed).map(\.text) == ["Samantha and Jon. Jon left.", "the Kestrel build"])
    #expect(GlossaryCorrector.rowsOnChangedLines(rows, in: changed) == [0])
    // Unchanged, both apply where they were proposed.
    let unchanged = [line("Sam and Jon. Jon left."), line("the Kestrol build")]
    #expect(GlossaryCorrector.apply(rows, to: unchanged).map(\.text) == ["Sam and Jon. Jonathan left.", "the Kestrel build"])
    #expect(GlossaryCorrector.rowsOnChangedLines(rows, in: unchanged).isEmpty)
    // A row whose line is gone has changed too; a row that names no line is applied as before.
    let gone = GlossaryCorrection(segmentIndex: 5, from: "Kestrol", to: "Kestrel", proposedLine: "the Kestrol build")
    #expect(GlossaryCorrector.rowsOnChangedLines([gone], in: unchanged) == [0])
    let plain = GlossaryCorrection(segmentIndex: 0, from: "Jon", to: "Jonathan")
    #expect(GlossaryCorrector.apply([plain], to: changed)[0].text == "Samantha and Jonathan. Jon left.")
    #expect(GlossaryCorrector.rowsOnChangedLines([plain], in: changed).isEmpty)
    // The sheet's sentence is drawn on the line the row was proposed on, the line it can apply to.
    #expect(GlossaryCorrector.contexts(of: [rows[0]], in: changed)
        == [ProposalContext(before: "Sam and Jon. ", match: "Jon", after: " left.")])
}

@Test("Two rules for one heard word give one row, and ticking every row changes only the reviewed occurrence (F939)")
func twoRulesForOneHeardWordChangeOnlyTheReviewedOccurrence() {
    let rules = [ReplacementRule(heard: "jon", preferred: "Jonathan"), ReplacementRule(heard: "jon", preferred: "John")]
    let segments = [line("jon met jon")]
    let proposed = ReplacementRuleMatcher.corrections(rules: rules, segments: segments)
    // Each occurrence is one row, the first rule's (since F967 every occurrence in the segment is a
    // row; until then only the first was, and the second "jon" waited for another Apply).
    #expect(proposed == [
        GlossaryCorrection(segmentIndex: 0, from: "jon", to: "Jonathan"),
        GlossaryCorrection(segmentIndex: 0, from: "jon", to: "Jonathan", characterOffset: 8),
    ])
    #expect(GlossaryCorrector.apply(proposed, to: segments)[0].text == "Jonathan met Jonathan")
    #expect(GlossaryCorrector.apply([proposed[0]], to: segments)[0].text == "Jonathan met jon")
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

@Test("Rows that change one place are found as alternatives, the way apply resolves them (F966)")
func rowsForOnePlaceAreAlternatives() {
    // Since F939 two ticked rows for one occurrence change it once, with the first row's spelling;
    // the sheet showed them as independent ticks and counted both. Their places are apply's own.
    let segments = [line("the Kestral build and the Kestral fix"), line("Jon said hi")]
    let rows = [
        GlossaryCorrection(segmentIndex: 0, from: "Kestral", to: "Kestrel"),
        GlossaryCorrection(segmentIndex: 0, from: "Kestral", to: "Kestrol"),
        GlossaryCorrection(segmentIndex: 0, from: "Kestral", to: "Kestrel", characterOffset: 26),
        GlossaryCorrection(segmentIndex: 1, from: "Jon", to: "Jonathan"),
        GlossaryCorrection(segmentIndex: 0, from: "Kestral build", to: "Kestrel Build"),
        GlossaryCorrection(segmentIndex: 7, from: "gone", to: "line"),
    ]
    // Rows 0, 1 and 4 overlap the first Kestral; row 2 is the second Kestral, alone; row 3 is another line.
    #expect(GlossaryCorrector.alternatives(of: rows, in: segments) == [0: 0, 1: 0, 4: 0])
    // Applying every row changes each group's place once, with its first row.
    #expect(GlossaryCorrector.apply(rows, to: segments).map(\.text) == ["the Kestrel build and the Kestrel fix", "Jonathan said hi"])
    #expect(GlossaryCorrector.alternatives(of: [rows[3]], in: segments).isEmpty)
}
