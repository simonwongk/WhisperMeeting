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

    // MARK: - Cross-segment repetition (F186)

    /// Below this many segments there is too little evidence to call a decode degenerate, and a false
    /// accusation on a short transcript is worse than silence.
    static let repetitionMinimumSegments = 20
    /// A decode is degenerate when this share or less of its lines are distinct. Measured against real
    /// transcripts: seven healthy recordings sat at 0.98–1.00, a real conversation full of "Yeah."/"Bye."
    /// acknowledgements sat at 0.48, and the observed loop sat at **0.016**. The bar is set well below
    /// the chatty-but-healthy case, because falsely accusing a good transcript is worse than missing a
    /// partial loop.
    static let repetitionUniqueRatioThreshold = 0.25
    /// …and one line must account for at least this share of the transcript. This is what separates a
    /// stuck decode from ordinary speech: the observed loop repeated a **two-character** line for 73% of
    /// the transcript, while real meetings repeat equally short fillers ("Yeah.", "嗯", "对") for only
    /// 11–30%. Line length cannot tell them apart — dominance can.
    static let repetitionDominanceThreshold = 0.5

    /// A plain-language notice when the transcript looks like a **looping decode** — the same line
    /// emitted over and over (F186).
    ///
    /// This is deliberately a *cross-segment* check. `classify` measures repetition **within** one
    /// segment (the model's `compression_ratio`, or F55's text-only equivalent), which a loop defeats
    /// completely: every individual line is clean, so the transcript is scored and reported at full
    /// confidence while being mostly one repeated sentence. Judging the segment list as a whole is the
    /// only way to see it, and it works on any engine because it needs no model metrics — which matters
    /// because the Qwen path emits none.
    ///
    /// Returns `nil` for healthy transcripts. It only ever *warns*: the recording is the source of
    /// truth, and the user decides whether to re-run with the other engine.
    public static func repetitionNotice(_ segments: [TranscriptSegment]) -> String? {
        let lines = segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count >= repetitionMinimumSegments else { return nil }

        var counts: [String: Int] = [:]
        for line in lines { counts[line, default: 0] += 1 }
        let uniqueRatio = Double(counts.count) / Double(lines.count)
        guard let repeats = counts.values.max() else { return nil }
        let dominance = Double(repeats) / Double(lines.count)
        guard uniqueRatio <= repetitionUniqueRatioThreshold,
              dominance >= repetitionDominanceThreshold else {
            return nil
        }

        let percent = Int((dominance * 100).rounded())
        return """
        This transcript looks like a decode that got stuck: one line repeats \(repeats) times, \
        about \(percent)% of it. The recording itself is fine — try Second Opinion with the other \
        engine, or transcribe it again.
        """
    }

    /// A compression-ratio-equivalent derived from text alone, for transcripts (Qwen, legacy) that
    /// carry no model metrics. Deterministic and framework-free — a degenerate loop repeats tokens,
    /// so total/distinct token count spikes above the same 2.4 threshold Whisper's real ratio uses.
    /// Space-delimited text scores by word (letters repeat too much to score by character); CJK runs
    /// with no word boundaries fall back to per-character repetition (F55).
    static func textCompressionRatio(_ text: String) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 1.0 }
        let words = trimmed.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        if words.count > 1 {
            let distinct = Set(words.map { $0.lowercased() })
            return Double(words.count) / Double(max(1, distinct.count))
        }
        let characters = trimmed.filter { !$0.isWhitespace }
        guard !characters.isEmpty else { return 1.0 }
        return Double(characters.count) / Double(max(1, Set(characters).count))
    }

    /// Returns the flags for a segment, or `nil` if it is truly unscored (no metrics and no text).
    /// A scored-but-clean segment returns `[]`. A metric-less segment with text is still scored via
    /// the text-only repetition heuristic, so the quality banner reaches Qwen/legacy transcripts.
    private static func classify(_ segment: TranscriptSegment) -> [SegmentQualityFlag]? {
        let hasMetrics = segment.avgLogprob != nil || segment.noSpeechProb != nil
            || segment.compressionRatio != nil
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasMetrics || !text.isEmpty else { return nil }

        var flags: [SegmentQualityFlag] = []

        // Repetition uses the model's compression ratio when present, else the text-only heuristic.
        let ratio = segment.compressionRatio ?? textCompressionRatio(text)
        if ratio > compressionRatioThreshold {
            flags.append(.repetitive)
        }
        // Likely-silence and low-confidence require real model metrics — never inferred from text.
        if (segment.noSpeechProb ?? 0) > silenceNoSpeechThreshold {
            flags.append(.likelySilence)
        }
        if let logprob = segment.avgLogprob, logprob < logprobThreshold {
            flags.append(.lowConfidence)
        }

        return flags
    }

    /// How far a flagged segment breaches the thresholds, summed across its signals, plus a small
    /// nudge per extra flag. Used only to order the review worst-first; never hides anything.
    private static func severity(of segment: TranscriptSegment, flags: [SegmentQualityFlag]) -> Double {
        var score = 0.0
        if let logprob = segment.avgLogprob { score += max(0, logprobThreshold - logprob) }
        let ratio = segment.compressionRatio ?? textCompressionRatio(segment.text)
        score += max(0, ratio - compressionRatioThreshold)
        if let noSpeech = segment.noSpeechProb { score += max(0, noSpeech - silenceNoSpeechThreshold) }
        score += 0.25 * Double(max(0, flags.count - 1))
        return score
    }
}
