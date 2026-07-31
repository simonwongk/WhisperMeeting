import Testing
@testable import WhisperCore

private func seg(_ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

/// F73 — comparing two engines' transcripts.
@Test("Transcript comparison marks agreement, divergence, and non-overlap")
func transcriptComparison() {
    let a = [seg(0, 2, "hello world"), seg(2, 4, "second segment")]

    // Identical inputs → all agree, zero divergences.
    let identical = TranscriptComparison.compare(a, a)
    #expect(identical.allSatisfy { $0.kind == .agree })
    #expect(identical.contains { $0.kind == .diverge } == false)

    // One differing word in an overlapping segment → exactly one divergence carrying both texts.
    let b = [seg(0, 2, "hello world"), seg(2, 4, "second segments")]
    let diff = TranscriptComparison.compare(a, b)
    #expect(diff.filter { $0.kind == .diverge }.count == 1)
    let diverged = diff.first { $0.kind == .diverge }!
    #expect(diverged.primaryText == "second segment")
    #expect(diverged.secondaryText == "second segments")

    // Disjoint timelines → non-overlapping, no crash.
    let disjoint = TranscriptComparison.compare([seg(0, 2, "x")], [seg(10, 12, "y")])
    #expect(disjoint.allSatisfy { $0.kind == .nonOverlapping })
}
