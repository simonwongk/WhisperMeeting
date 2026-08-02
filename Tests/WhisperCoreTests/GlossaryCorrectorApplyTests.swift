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
