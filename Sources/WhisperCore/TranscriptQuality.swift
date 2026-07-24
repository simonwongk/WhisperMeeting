import Foundation

/// Why a transcript segment is likely to need a human look. Each case mirrors one of Whisper's own
/// per-segment quality signals, using the model's own default rejection thresholds — so a flag here
/// means the same thing Whisper's internal quality gate means.
public enum SegmentQualityFlag: String, Sendable, Codable, CaseIterable {
    /// `avg_logprob` below Whisper's `logprob_threshold` (-1.0): a shaky, low-probability guess.
    case lowConfidence
    /// `no_speech_prob` above a high bar (0.8): the window very likely wasn't speech, yet text was
    /// emitted — the classic silence hallucination (e.g. "Thank you for watching." over dead air).
    /// Deliberately independent of confidence: Whisper *skips* windows that are both high-no-speech
    /// AND low-confidence, so the hallucinations that actually survive into a transcript are the
    /// ones it emitted *confidently*. Gating on low confidence (as before) made this flag
    /// unreachable — it only matched segments Whisper had already dropped.
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
    /// How urgently this segment needs a look (larger = worse): the summed magnitude by which it
    /// breaches Whisper's thresholds, plus a nudge for carrying multiple flags. Used to order the
    /// review worst-first instead of by transcript position.
    public let severity: Double

    public var id: Int { index }

    public init(index: Int, flags: [SegmentQualityFlag], severity: Double = 0) {
        self.index = index
        self.flags = flags
        self.severity = severity
    }
}

/// The result of reviewing a transcript for likely-unreliable segments.
public struct TranscriptQualityReport: Sendable, Equatable {
    /// Segments with at least one quality flag, in transcript order. (The inline transcript markers
    /// use this order; the review step-through uses `flaggedBySeverity`.)
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

    /// Flagged segments ordered worst-first (highest severity), so a review walks the segments that
    /// most need attention before the marginal ones. Ties fall back to transcript order for a
    /// stable, deterministic sequence. Nothing is hidden — this is the full `flagged` set, reordered.
    public var flaggedBySeverity: [FlaggedSegment] {
        flagged.enumerated()
            .sorted { lhs, rhs in
                lhs.element.severity != rhs.element.severity
                    ? lhs.element.severity > rhs.element.severity
                    : lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}

/// Pure classification of transcript segments by Whisper's own confidence metrics.
public enum TranscriptQuality {
    // Whisper's default decode-rejection thresholds (verified against openai/whisper transcribe.py).
    static let logprobThreshold = -1.0
    static let compressionRatioThreshold = 2.4
    /// Whisper skips a window when `no_speech_prob > 0.6 AND avg_logprob <= -1.0`, so anything that
    /// survives with high no_speech_prob was emitted confidently. We flag those on no_speech alone,
    /// but at a stricter 0.8 bar than Whisper's 0.6 skip gate to avoid over-flagging brief confident
    /// utterances that legitimately score a little high on no_speech.
    static let silenceNoSpeechThreshold = 0.8

    public static func review(_ segments: [TranscriptSegment]) -> TranscriptQualityReport {
        var flagged: [FlaggedSegment] = []
        var scoredCount = 0

        for (index, segment) in segments.enumerated() {
            guard let flags = classify(segment) else { continue }
            scoredCount += 1
            if !flags.isEmpty {
                flagged.append(FlaggedSegment(
                    index: index,
                    flags: flags,
                    severity: severity(of: segment, flags: flags)
                ))
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

        // Repetition and likely-silence are independent signals; a segment can carry any combination.
        if (segment.compressionRatio ?? 0) > compressionRatioThreshold {
            flags.append(.repetitive)
        }
        if (segment.noSpeechProb ?? 0) > silenceNoSpeechThreshold {
            flags.append(.likelySilence)
        }
        if (segment.avgLogprob ?? 0) < logprobThreshold {
            flags.append(.lowConfidence)
        }

        return flags
    }

    /// How far a flagged segment breaches the thresholds, summed across its signals, plus a small
    /// nudge per extra flag. Used only to order the review worst-first; never hides anything.
    private static func severity(of segment: TranscriptSegment, flags: [SegmentQualityFlag]) -> Double {
        var score = 0.0
        if let logprob = segment.avgLogprob { score += max(0, logprobThreshold - logprob) }
        if let compression = segment.compressionRatio { score += max(0, compression - compressionRatioThreshold) }
        if let noSpeech = segment.noSpeechProb { score += max(0, noSpeech - silenceNoSpeechThreshold) }
        score += 0.25 * Double(max(0, flags.count - 1))
        return score
    }
}
