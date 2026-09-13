import Foundation

/// What a diarization interval claims. Anonymous by construction — a kind never names a person,
/// and `uncertain`/`overlap` exist so ambiguity can be shown rather than resolved silently (F218).
public enum SpeakerTurnKind: String, Codable, Sendable, Equatable {
    /// One voice cluster is active.
    case speech
    /// More than one voice may be active; no single label may be shown.
    case overlap
    /// The runtime produced an interval it could not attribute with confidence.
    case uncertain

    /// Lenient decoding: a kind written by a newer build must not fail the whole artifact, and an
    /// unrecognized claim must degrade to "uncertain" rather than to confident speech
    /// (`AGENTS.md` — enums reachable from a persisted type decode leniently or fail closed).
    ///
    /// This degrades on the way IN only. Preservation on the way back OUT happens in
    /// `SpeakerTurn.rawKind`, which stores the string verbatim — degrading here as well would
    /// destroy a newer build's kinds on any read-modify-write.
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = SpeakerTurnKind(rawValue: value) ?? .uncertain
    }
}

/// One anonymous voice-cluster interval. `clusterID` is dense and local to a single result — it is
/// never a person, never stable across reruns, and never compared across meetings.
public struct SpeakerTurn: Codable, Sendable, Equatable {
    public let startSeconds: TimeInterval
    public let endSeconds: TimeInterval
    public let clusterID: Int

    /// The kind exactly as it was written. Stored raw so a kind this build does not recognize
    /// survives a read-modify-write — `renameSpeaker` re-encodes every turn, and degrading an
    /// unknown kind to "uncertain" on the way out would destroy a newer build's data
    /// (AGENTS.md — compatibility is assessed in BOTH directions). Same remedy as `MediaSource.kind`.
    private let rawKind: String

    /// Unknown raw values degrade to `.uncertain` for display only; they are re-encoded verbatim.
    public var kind: SpeakerTurnKind { SpeakerTurnKind(rawValue: rawKind) ?? .uncertain }

    private enum CodingKeys: String, CodingKey {
        case startSeconds, endSeconds, clusterID, rawKind = "kind"
    }

    public init(startSeconds: TimeInterval, endSeconds: TimeInterval, clusterID: Int, kind: SpeakerTurnKind) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.clusterID = clusterID
        self.rawKind = kind.rawValue
    }
}

public enum SpeakerTurnValidationError: Error, Sendable, Equatable {
    case notFinite
    /// The recording duration the turns are measured against is not a usable number.
    case invalidDuration
    case negativeStart
    case reversedInterval
    case exceedsDuration
    case negativeCluster
    case unsortedTurns
    case tooManyTurns
}

/// Validation for untrusted diarization output — a model result, a file written by another build,
/// or a corrupted sidecar. Nothing reaches storage or the UI without passing through here (F218).
public enum SpeakerTurns {
    /// A 12-hour meeting at one turn per second is 43 200; 200 000 is far above any real result and
    /// far below anything that could exhaust memory.
    public static let maximumTurnCount = 200_000

    /// The runtime reports times to three decimal places against its own duration probe, which can
    /// round a hair past ours. Tolerate that, not a real out-of-range claim.
    public static let durationTolerance: TimeInterval = 0.05

    /// Rejects any interval that is impossible, out of range, or out of order. Turns are never
    /// silently repaired or reordered: a result we cannot trust is one we do not show.
    public static func validate(
        _ turns: [SpeakerTurn],
        durationSeconds: TimeInterval
    ) throws -> [SpeakerTurn] {
        guard turns.count <= maximumTurnCount else { throw SpeakerTurnValidationError.tooManyTurns }
        // The duration is this gate's own yardstick, so it is checked before it is used to judge
        // anything: `max(0, .infinity)` accepts every out-of-range turn and `max(0, .nan)` rejects
        // every turn at all — one class of bad input, two opposite outcomes, neither a policy.
        guard durationSeconds.isFinite else { throw SpeakerTurnValidationError.invalidDuration }
        let limit = max(0, durationSeconds) + durationTolerance
        var previousStart = -Double.greatestFiniteMagnitude
        for turn in turns {
            guard turn.startSeconds.isFinite, turn.endSeconds.isFinite else {
                throw SpeakerTurnValidationError.notFinite
            }
            guard turn.startSeconds >= 0 else { throw SpeakerTurnValidationError.negativeStart }
            guard turn.endSeconds > turn.startSeconds else {
                throw SpeakerTurnValidationError.reversedInterval
            }
            guard turn.endSeconds <= limit else { throw SpeakerTurnValidationError.exceedsDuration }
            guard turn.clusterID >= 0 else { throw SpeakerTurnValidationError.negativeCluster }
            guard turn.startSeconds >= previousStart else {
                throw SpeakerTurnValidationError.unsortedTurns
            }
            previousStart = turn.startSeconds
        }
        return turns
    }
}
