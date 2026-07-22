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

@Test("High no-speech probability with low confidence flags likely silence")
func likelySilenceFlagged() {
    // The classic silence hallucination: high no_speech_prob AND low logprob.
    let report = TranscriptQuality.review([
        seg("Thank you for watching.", logprob: -1.2, noSpeech: 0.85, compression: 1.1)
    ])
    #expect(report.flagged.count == 1)
    #expect(report.flagged.first?.flags == [.likelySilence])
}

@Test("High no-speech probability but confident text is NOT silence")
func confidentDespiteNoSpeechProb() {
    // Whisper's own rule: don't treat as silent if the logprob is high enough.
    let report = TranscriptQuality.review([
        seg("Okay.", logprob: -0.3, noSpeech: 0.9, compression: 1.0)
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
    let report = TranscriptQuality.review([
        seg("you you you you you", logprob: -1.5, noSpeech: 0.8, compression: 2.6)
    ])
    let flags = report.flagged.first?.flags ?? []
    #expect(flags.contains(.likelySilence))
    #expect(flags.contains(.repetitive))
    // lowConfidence is subsumed by likelySilence (same logprob signal), not double-reported.
    #expect(!flags.contains(.lowConfidence))
}

@Test("Boundary values exactly at Whisper's thresholds are not flagged")
func thresholdBoundaries() {
    // Whisper uses strict comparisons (> / <), so values sitting exactly on the threshold pass.
    let report = TranscriptQuality.review([
        seg("edge", logprob: -1.0, noSpeech: 0.6, compression: 2.4)
    ])
    #expect(report.flagged.isEmpty)
}

@Test("Segments without metrics are unscored, never flagged")
func missingMetricsUnscored() {
    let report = TranscriptQuality.review([
        seg("legacy transcript segment", logprob: nil, noSpeech: nil, compression: nil)
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
        seg("no metrics here")
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
