import Foundation
import Testing
@testable import WhisperCore

private func seg(
    _ text: String,
    logprob: Double? = nil,
    noSpeech: Double? = nil,
    compression: Double? = nil,
    start: Double? = 0
) -> TranscriptSegment {
    TranscriptSegment(
        speaker: nil,
        start: start,
        end: start.map { $0 + 1 },
        text: text,
        avgLogprob: logprob,
        noSpeechProb: noSpeech,
        compressionRatio: compression
    )
}

@Test("A clean, confident segment is not flagged")
func cleanSegmentUnflagged() {
    let report = TranscriptQuality.review([
        seg("Good morning everyone.", logprob: -0.2, noSpeech: 0.01, compression: 1.4)
    ])
    #expect(report.flagged.isEmpty)
    #expect(report.scoredCount == 1)
    #expect(report.confidence == 1.0)
    #expect(!report.isUnscored)
}

@Test("A low average log-probability flags low confidence")
func lowConfidenceFlagged() {
    let report = TranscriptQuality.review([
        seg("uh the the quarterly", logprob: -1.6, noSpeech: 0.05, compression: 1.5)
    ])
    #expect(report.flagged.count == 1)
    #expect(report.flagged.first?.flags == [.lowConfidence])
}

@Test("A confident hallucination over dead air (high no-speech, high confidence) flags likely silence")
func likelySilenceFlagged() {
    // This is exactly the case Whisper EMITS — it only skips high-no-speech windows when they're
    // also low-confidence, so the hallucinations that survive are confident. The flag must catch it.
    let report = TranscriptQuality.review([
        seg("Thank you for watching.", logprob: -0.4, noSpeech: 0.9, compression: 1.1)
    ])
    #expect(report.flagged.count == 1)
    #expect(report.flagged.first?.flags == [.likelySilence])
}

@Test("Moderately elevated no-speech with confidence is not flagged (below the 0.8 bar)")
func moderateNoSpeechConfidentNotFlagged() {
    // no_speech in Whisper's 0.6 skip zone but below our stricter 0.8 flag bar, and confident: a
    // brief real utterance, not a hallucination — must stay unflagged so we don't cry wolf.
    let report = TranscriptQuality.review([
        seg("Okay.", logprob: -0.3, noSpeech: 0.7, compression: 1.0)
    ])
    #expect(report.flagged.isEmpty)
}

@Test("A high compression ratio flags repetitive/degenerate output")
func repetitiveFlagged() {
    let report = TranscriptQuality.review([
        seg("yeah yeah yeah yeah yeah yeah yeah", logprob: -0.5, noSpeech: 0.02, compression: 2.9)
    ])
    #expect(report.flagged.count == 1)
    #expect(report.flagged.first?.flags == [.repetitive])
}

@Test("Silence and repetition can both flag the same segment")
func multipleFlags() {
    // A repetitive, confident hallucination over quiet audio: high no_speech + high compression,
    // but emitted confidently (so not low-confidence).
    let report = TranscriptQuality.review([
        seg("thank you thank you thank you thank you", logprob: -0.5, noSpeech: 0.9, compression: 2.7)
    ])
    let flags = report.flagged.first?.flags ?? []
    #expect(flags.contains(.likelySilence))
    #expect(flags.contains(.repetitive))
    #expect(!flags.contains(.lowConfidence))
}

@Test("flaggedBySeverity orders the worst segments first and hides nothing")
func severityOrdering() {
    let report = TranscriptQuality.review([
        seg("mild", logprob: -1.1, noSpeech: 0.02, compression: 1.2),        // idx0: barely low-confidence
        seg("clean", logprob: -0.2, noSpeech: 0.01, compression: 1.1),       // idx1: unflagged
        seg("severe loop", logprob: -3.0, noSpeech: 0.05, compression: 3.0), // idx2: deep low-conf + repetitive
    ])
    // Nothing hidden — the full flagged set is present, just reordered.
    #expect(report.flaggedBySeverity.count == 2)
    #expect(report.flaggedBySeverity.map(\.index) == [2, 0])  // worst first
    #expect(report.flagged.map(\.index) == [0, 2])            // plain list stays in transcript order
}

@Test("Boundary values exactly at Whisper's thresholds are not flagged")
func thresholdBoundaries() {
    // Whisper uses strict comparisons (> / <), so values sitting exactly on the threshold pass.
    let report = TranscriptQuality.review([
        seg("edge", logprob: -1.0, noSpeech: 0.6, compression: 2.4)
    ])
    #expect(report.flagged.isEmpty)
}

@Test("A metric-less segment with no text is unscored (metric-less WITH text is scored via F55)")
func missingMetricsUnscored() {
    // Truly unscored now means no metrics AND no text; a metric-less segment with text is scored
    // via the text-only repetition heuristic (covered by textOnlyRepetitionFlag).
    let report = TranscriptQuality.review([
        seg("", logprob: nil, noSpeech: nil, compression: nil)
    ])
    #expect(report.flagged.isEmpty)
    #expect(report.scoredCount == 0)
    #expect(report.isUnscored)
}

@Test("Confidence is the fraction of scored segments with no flags")
func confidenceFraction() {
    let report = TranscriptQuality.review([
        seg("clean one", logprob: -0.3, noSpeech: 0.01, compression: 1.2),
        seg("clean two", logprob: -0.4, noSpeech: 0.02, compression: 1.3),
        seg("shaky", logprob: -1.8, noSpeech: 0.1, compression: 1.4),
        seg("") // truly unscored: no metrics and no text
    ])
    // 3 scored (the 4th is unscored), 1 flagged → 2/3 clean.
    #expect(report.scoredCount == 3)
    #expect(report.flagged.count == 1)
    #expect(abs(report.confidence - 2.0 / 3.0) < 1e-9)
}

@Test("Flagged segments keep their original transcript index for navigation")
func flaggedKeepIndex() {
    let report = TranscriptQuality.review([
        seg("clean", logprob: -0.2, noSpeech: 0.01, compression: 1.1),
        seg("clean", logprob: -0.2, noSpeech: 0.01, compression: 1.1),
        seg("bad", logprob: -2.0, noSpeech: 0.05, compression: 1.4)
    ])
    #expect(report.flagged.map(\.index) == [2])
}

@Test("An empty transcript yields an empty unscored report")
func emptyTranscript() {
    let report = TranscriptQuality.review([])
    #expect(report.flagged.isEmpty)
    #expect(report.scoredCount == 0)
    #expect(report.isUnscored)
    #expect(report.confidence == 1.0)
}

@Test("Confidence metrics survive a Codable round-trip and old JSON decodes with nil metrics")
func metricsCodableRoundTrip() throws {
    let original = seg("hello", logprob: -0.7, noSpeech: 0.3, compression: 1.9)
    let data = try JSONEncoder().encode(original)
    let restored = try JSONDecoder().decode(TranscriptSegment.self, from: data)
    #expect(restored == original)
    #expect(restored.avgLogprob == -0.7)

    // A transcript stored before this feature has no metric keys — it must still decode.
    let legacy = #"{"start":0,"end":1,"text":"legacy"}"#.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: legacy)
    #expect(decoded.text == "legacy")
    #expect(decoded.avgLogprob == nil)
    #expect(decoded.noSpeechProb == nil)
    #expect(decoded.compressionRatio == nil)
}

@Test("Each flag reports a human-readable reason")
func flagReasons() {
    #expect(SegmentQualityFlag.lowConfidence.reason.isEmpty == false)
    #expect(SegmentQualityFlag.likelySilence.reason.isEmpty == false)
    #expect(SegmentQualityFlag.repetitive.reason.isEmpty == false)
}

@Test("Text-only repetition is flagged without model metrics; clean metric-less text stays unflagged")
func textOnlyRepetitionFlag() {
    // Qwen-style segment: all model metrics nil, degenerate loop text.
    let repetitive = TranscriptSegment(speaker: nil, start: 0, end: 1, text: "yes yes yes yes yes yes yes")
    let report = TranscriptQuality.review([repetitive])
    #expect(report.flagged.first?.flags.contains(.repetitive) == true)
    #expect(report.isUnscored == false)

    // A clean metric-less segment is scored (text present) but unflagged; silence/lowConfidence
    // never fire without real metrics.
    let clean = TranscriptSegment(speaker: nil, start: 0, end: 1, text: "the team agreed on the plan today")
    let cleanReport = TranscriptQuality.review([clean])
    #expect(cleanReport.flagged.isEmpty)
    #expect(cleanReport.isUnscored == false)
    #expect(!cleanReport.flagged.contains { $0.flags.contains(.lowConfidence) || $0.flags.contains(.likelySilence) })
}
