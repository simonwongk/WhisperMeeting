import Foundation

/// Why a transcript segment is likely to need a human look. Each case mirrors one of Whisper's own
/// per-segment quality signals, using the model's own default rejection thresholds — so a flag here
/// means the same thing Whisper's internal quality gate means.
public enum SegmentQualityFlag: String, Sendable, Codable, CaseIterable {
    /// `avg_logprob` below Whisper's `logprob_threshold` (-1.0): a shaky, low-probability guess.
    case lowConfidence
    /// `no_speech_prob` above `no_speech_threshold` (0.6) *and* low confidence: the classic
    /// silence hallucination (e.g. "Thank you for watching." over dead air).
    case likelySilence
    /// `compression_ratio` above `compression_ratio_threshold` (2.4): repetitive / degenerate text.
    case repetitive

    public var reason: String {
        switch self {
        case .lowConfidence: return "Low confidence — the model wasn't sure of these words."
        case .likelySilence: return "Likely silence — may be filler the model invented over quiet audio."
        case .repetitive: return "Repetitive — the text loops, a sign of a degenerate decode."
        }
    }
}

/// One flagged segment, carrying its original index in the transcript so the UI can navigate to it.
public struct FlaggedSegment: Sendable, Equatable, Identifiable {
    public let index: Int
    public let flags: [SegmentQualityFlag]

    public var id: Int { index }

    public init(index: Int, flags: [SegmentQualityFlag]) {
        self.index = index
        self.flags = flags
    }
}

/// The result of reviewing a transcript for likely-unreliable segments.
public struct TranscriptQualityReport: Sendable, Equatable {
    /// Segments with at least one quality flag, in transcript order.
    public let flagged: [FlaggedSegment]
    /// How many segments carried Whisper metrics (older/dictation transcripts carry none).
    public let scoredCount: Int

    public init(flagged: [FlaggedSegment], scoredCount: Int) {
        self.flagged = flagged
        self.scoredCount = scoredCount
    }

    /// No segment carried metrics — nothing to review; the UI stays silent.
    public var isUnscored: Bool { scoredCount == 0 }

    /// Fraction of scored segments with no flags, in `0...1`. An unscored transcript is 1.0
    /// (we make no claim rather than a false low score).
    public var confidence: Double {
        guard scoredCount > 0 else { return 1.0 }
        return Double(scoredCount - flagged.count) / Double(scoredCount)
    }
}

/// Pure classification of transcript segments by Whisper's own confidence metrics.
public enum TranscriptQuality {
    // Whisper's default decode-rejection thresholds (verified against openai/whisper transcribe.py).
    static let logprobThreshold = -1.0
    static let compressionRatioThreshold = 2.4
    static let noSpeechThreshold = 0.6

    public static func review(_ segments: [TranscriptSegment]) -> TranscriptQualityReport {
        var flagged: [FlaggedSegment] = []
        var scoredCount = 0

        for (index, segment) in segments.enumerated() {
            guard let flags = classify(segment) else { continue }
            scoredCount += 1
            if !flags.isEmpty {
                flagged.append(FlaggedSegment(index: index, flags: flags))
            }
        }

        return TranscriptQualityReport(flagged: flagged, scoredCount: scoredCount)
    }

    /// Returns the flags for a segment, or `nil` if it has no metrics (unscored).
    /// A scored-but-clean segment returns `[]`.
    private static func classify(_ segment: TranscriptSegment) -> [SegmentQualityFlag]? {
        // A segment is "scored" only if it carries the signals we actually use.
        guard segment.avgLogprob != nil || segment.noSpeechProb != nil
            || segment.compressionRatio != nil else {
            return nil
        }

        var flags: [SegmentQualityFlag] = []

        let lowLogprob = (segment.avgLogprob ?? 0) < logprobThreshold

        // Repetition is independent of confidence.
        if (segment.compressionRatio ?? 0) > compressionRatioThreshold {
            flags.append(.repetitive)
        }

        // Whisper's own rule: silence requires high no_speech_prob AND low confidence.
        let likelySilence = (segment.noSpeechProb ?? 0) > noSpeechThreshold && lowLogprob
        if likelySilence {
            flags.append(.likelySilence)
        } else if lowLogprob {
            // Low confidence not already explained by the silence rule.
            flags.append(.lowConfidence)
        }

        return flags
    }
}
