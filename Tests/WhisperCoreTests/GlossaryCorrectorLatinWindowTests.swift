import Foundation
import Testing
@testable import WhisperCore

// Correct Toward Vocabulary's Latin windows are whitespace-separated words (F65, kept by F536).
// F819: a window's phrase kept the punctuation attached to its words, so applying "Kestrol," →
// "Kestrel" deleted the comma.

private func seg(_ text: String) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: 0, end: 1, text: text)
}

@Test("A Latin proposal leaves the punctuation around the misheard word where it was (F819)")
func latinProposalKeepsAttachedPunctuation() {
    let segments = [seg("the Kestrol, release"), seg("(Kestrol) shipped"), seg("we deployed cooper netties.")]
    let corrections = GlossaryCorrector.corrections(vocabulary: ["Kestrel", "Kubernetes"], segments: segments)
    #expect(corrections == [
        GlossaryCorrection(segmentIndex: 0, from: "Kestrol", to: "Kestrel"),
        GlossaryCorrection(segmentIndex: 1, from: "Kestrol", to: "Kestrel"),
        GlossaryCorrection(segmentIndex: 2, from: "cooper netties", to: "Kubernetes"),
    ])
    let applied = GlossaryCorrector.apply(corrections, to: segments).map(\.text)
    #expect(applied == ["the Kestrel, release", "(Kestrel) shipped", "we deployed Kubernetes."])
}
