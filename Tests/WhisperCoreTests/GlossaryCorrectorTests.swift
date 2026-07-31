import Testing
@testable import WhisperCore

private func seg(_ text: String) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: 0, end: 1, text: text)
}

/// F65 — reviewable near-miss corrections toward the user's vocabulary.
@Test("Glossary corrector proposes near-miss corrections and skips exact/cross-script/distant")
func glossaryCorrector() {
    // A near-miss yields exactly one proposed correction carrying the original phrase and the term.
    let near = GlossaryCorrector.corrections(
        vocabulary: ["Kubernetes"],
        segments: [seg("we deployed cooper netties today")]
    )
    #expect(near.count == 1)
    #expect(near.first?.from == "cooper netties")
    #expect(near.first?.to == "Kubernetes")

    // An exact match proposes nothing.
    #expect(GlossaryCorrector.corrections(
        vocabulary: ["Kubernetes"], segments: [seg("we use Kubernetes daily")]
    ).isEmpty)

    // A cross-script candidate proposes nothing.
    #expect(GlossaryCorrector.corrections(
        vocabulary: ["北京"], segments: [seg("we met in beijing")]
    ).isEmpty)

    // A too-distant token proposes nothing.
    #expect(GlossaryCorrector.corrections(
        vocabulary: ["Kubernetes"], segments: [seg("we ate a banana")]
    ).isEmpty)
}
