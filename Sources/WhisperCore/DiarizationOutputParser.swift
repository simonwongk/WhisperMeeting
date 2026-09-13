import Foundation

/// One line of the runtime's stdout, before remapping. `rawSpeaker` is the runtime's own cluster
/// number, which is **not dense** — a two-speaker file really does emit `speaker_00`/`speaker_02`.
public struct RawDiarizationTurn: Sendable, Equatable {
    public let startSeconds: TimeInterval
    public let endSeconds: TimeInterval
    public let rawSpeaker: Int
    public let confidence: Double?

    public init(startSeconds: TimeInterval, endSeconds: TimeInterval, rawSpeaker: Int, confidence: Double?) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.rawSpeaker = rawSpeaker
        self.confidence = confidence
    }
}

/// Why speaker analysis could not produce turns (F219). Every message ends by saying the transcript
/// is untouched: analysis is an optional extra, and a failure here must never read as data loss.
public enum LocalDiarizationError: LocalizedError, Sendable, Equatable {
    case runtimeNotInstalled
    case runtimeDamaged(String)
    case audioUnreadable(String)
    case sampleRateMismatch(String)
    case processFailed(String)

    public var errorDescription: String? {
        switch self {
        case .runtimeNotInstalled:
            "The speaker-analysis model is not installed. Install it in Settings to analyze speaker turns."
        case .runtimeDamaged:
            "The speaker-analysis model files are missing or damaged. Reinstall it in Settings; your transcript is unchanged."
        case .audioUnreadable:
            "This meeting's recording could not be read for analysis. Your transcript is unchanged."
        case .sampleRateMismatch:
            "The audio prepared for analysis was in the wrong format. Your transcript is unchanged."
        case let .processFailed(detail):
            "Speaker analysis did not finish. Your transcript is unchanged. \(detail)"
        }
    }
}

/// Pure parsing of the diarization runtime's line grammar (F219). Kept separate from the process
/// plumbing so every rule below is testable without a model, audio, or a subprocess.
public enum DiarizationOutputParser {
    /// `0.031 -- 8.485 speaker_00 confidence=0.707`, with confidence present only when the runtime
    /// was asked for it.
    private static let segmentPattern = try! NSRegularExpression(
        pattern: #"^\s*([0-9]+\.[0-9]+)\s*--\s*([0-9]+\.[0-9]+)\s+speaker_([0-9]+)(?:\s+confidence=(n/a|-?[0-9.]+))?\s*$"#
    )
    private static let progressPattern = try! NSRegularExpression(
        pattern: #"^\s*progress\s+([0-9]+\.[0-9]+)%\s*$"#
    )

    /// The runtime reports this when only one cluster formed, or when no overlapping embedding
    /// interval existed. It is "unavailable", not a low score, and must never be thresholded.
    public static let unavailableConfidence: Double = -2.0

    public static func turn(from line: String) -> RawDiarizationTurn? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = segmentPattern.firstMatch(in: line, range: range) else { return nil }
        func group(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: line) else { return nil }
            return String(line[range])
        }
        guard let start = group(1).flatMap(Double.init),
              let end = group(2).flatMap(Double.init),
              let speaker = group(3).flatMap(Int.init) else { return nil }
        // `confidence=n/a` is emitted verbatim whenever only one cluster formed. It is not a
        // number and it is not a score — it means "unavailable". Parsing it as a failed Double is
        // correct (nil), but the PATTERN must accept it, or the whole line fails to match and every
        // turn of a single-speaker recording is silently discarded. Measured on the F217 corpus:
        // `mono_1spk` and `zh_2spk_alt` emit it for 100% of their turns.
        return RawDiarizationTurn(
            startSeconds: start,
            endSeconds: end,
            rawSpeaker: speaker,
            confidence: group(4).flatMap(Double.init)
        )
    }

    public static func progress(from line: String) -> Double? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = progressPattern.firstMatch(in: line, range: range),
              let percentRange = Range(match.range(at: 1), in: line),
              let percent = Double(line[percentRange]) else { return nil }
        return min(1, max(0, percent / 100))
    }

    /// Remaps the runtime's sparse cluster numbers onto dense `0..<n` in first-appearance order, so
    /// "Speaker 1" is the first voice heard rather than an arbitrary internal index, and marks a
    /// low-confidence turn uncertain so the overlay abstains instead of showing a confident guess.
    public static func densify(
        _ raw: [RawDiarizationTurn],
        uncertainBelowConfidence threshold: Double
    ) -> [SpeakerTurn] {
        var mapping: [Int: Int] = [:]
        var next = 0
        return raw.map { turn in
            let clusterID: Int
            if let existing = mapping[turn.rawSpeaker] {
                clusterID = existing
            } else {
                clusterID = next
                mapping[turn.rawSpeaker] = next
                next += 1
            }
            // An absent confidence (the flag was off) and the -2.0 sentinel (only one cluster, so
            // there was nothing to compare against) both mean "no score" — thresholding either one
            // would mark every turn of a monologue uncertain and label nothing at all.
            let isUncertain: Bool
            if let confidence = turn.confidence, confidence != unavailableConfidence {
                isUncertain = confidence < threshold
            } else {
                isUncertain = false
            }
            return SpeakerTurn(
                startSeconds: turn.startSeconds,
                endSeconds: turn.endSeconds,
                clusterID: clusterID,
                kind: isUncertain ? .uncertain : .speech
            )
        }
    }

    /// Maps the runtime's failure markers onto distinct errors. All four config/IO failures exit
    /// 255, so the marker text is the only discriminator — `exitStatus` is carried for the caller's
    /// diagnostics rather than used to choose a case.
    public static func classify(errorOutput: String, exitStatus: Int32) -> LocalDiarizationError {
        if errorOutput.contains("Expect sample rate") { return .sampleRateMismatch(errorOutput) }
        if errorOutput.contains("Failed to read") { return .audioUnreadable(errorOutput) }
        if errorOutput.contains("Errors in config!") { return .runtimeDamaged(errorOutput) }
        return .processFailed(errorOutput)
    }
}
