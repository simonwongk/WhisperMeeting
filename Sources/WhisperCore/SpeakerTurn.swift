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
    /// More distinct voices than a meeting can have — a clustering failure, not a crowd (F342).
    case tooManyClusters
}

/// One interval exactly as a diarization runtime reported it, before remapping or validation.
///
/// `rawSpeaker` is generic because runtimes do not agree on what a cluster identity is: sherpa-onnx
/// numbered them sparsely (`speaker_00`, `speaker_02`, no `speaker_01`), FluidAudio names them
/// (`"S1"`, `"S2"`). Keying on whatever the runtime itself produced means an unfamiliar id is
/// merely a different key — never a parse that fails open, collapses every turn onto one cluster,
/// and shows two voices as one confidently-labelled speaker, which is the single error
/// `SpeakerOverlay` cannot detect (it sees one cluster, no competitor, no overlap).
public struct RawDiarizationTurn<ID: Hashable & Sendable>: Sendable, Equatable {
    public let startSeconds: TimeInterval
    public let endSeconds: TimeInterval
    public let rawSpeaker: ID
    /// The runtime's own per-turn confidence, when it reports one at all. `nil` means "no score" —
    /// which is not a low score, and must never be thresholded as if it were.
    public let confidence: Double?

    public init(startSeconds: TimeInterval, endSeconds: TimeInterval, rawSpeaker: ID, confidence: Double?) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.rawSpeaker = rawSpeaker
        self.confidence = confidence
    }
}

/// Validation for untrusted diarization output — a model result, a file written by another build,
/// or a corrupted sidecar. Nothing reaches storage or the UI without passing through here (F218).
public enum SpeakerTurns {
    /// A 12-hour meeting at one turn per second is 43 200; 200 000 is far above any real result and
    /// far below anything that could exhaust memory.
    public static let maximumTurnCount = 200_000

    /// Distinct clusters above which a result is a clustering failure rather than a meeting (F342).
    ///
    /// The threshold that guards against over-splitting (`clusterThreshold`, 0.60) was derived on
    /// AMI — four-speaker headset-mix audio, which at 0.30 still resolves 16 of 18 meetings to
    /// exactly four clusters. That corpus is structurally incapable of producing the failure the
    /// threshold guards against, so the calibration is not also a backstop. The failure itself has
    /// been seen here: 179 clusters and a 3,201 MB artifact on this app's own laptop-microphone
    /// plus system-audio mix (`docs/DIARIZATION_SCORECARD.md`).
    ///
    /// 64 is far above any meeting this app records — the two real meetings measured produce 4 —
    /// and far below the failure, so a result that trips this is one nobody should be shown.
    /// Refusing leaves the transcript untouched and the meeting re-analysable, which is what the
    /// other validation failures do.
    public static let maximumClusterCount = 64

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
        guard Set(turns.map(\.clusterID)).count <= maximumClusterCount else {
            throw SpeakerTurnValidationError.tooManyClusters
        }
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

    /// Remaps a runtime's own cluster ids onto dense `0..<n` in **first-appearance order**, and
    /// marks a low-confidence turn uncertain so the overlay abstains instead of showing a
    /// confident guess.
    ///
    /// First-appearance order is the whole point: "Speaker 1" must be the first voice heard, not an
    /// arbitrary internal index. A runtime's ids are private to its own clustering pass — sparse
    /// integers, generated names, whatever it happened to allocate — and carry no meaning a reader
    /// could use. Showing them raw would label the first person to speak "Speaker 3" in one meeting
    /// and "Speaker 1" in the next, for no reason a user could ever discover.
    ///
    /// Runtime-agnostic by construction, which is why it outlived the runtime it was written for:
    /// every diarizer needs this remap, and none of them can do it for us.
    ///
    /// `raw` must already be in time order. First-appearance only means "first voice heard" if the
    /// turns are sorted when the mapping is built, and `validate` rejects unsorted turns anyway.
    public static func densify<ID>(
        _ raw: [RawDiarizationTurn<ID>],
        uncertainBelowConfidence threshold: Double
    ) -> [SpeakerTurn] {
        var mapping: [ID: Int] = [:]
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
            // An absent confidence means the runtime reported no score, not a score of zero.
            // Thresholding it would mark every turn of a runtime that scores nothing uncertain,
            // and label nothing at all.
            let isUncertain = turn.confidence.map { $0 < threshold } ?? false
            return SpeakerTurn(
                startSeconds: turn.startSeconds,
                endSeconds: turn.endSeconds,
                clusterID: clusterID,
                kind: isUncertain ? .uncertain : .speech
            )
        }
    }
}
