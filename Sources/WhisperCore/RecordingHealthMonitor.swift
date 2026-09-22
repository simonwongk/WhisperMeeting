import Foundation

public enum RecordingChannel: Sendable, Equatable {
    case microphone
    case systemAudio
}

public struct RecordingAudioLevel: Sendable, Equatable {
    public let rms: Float
    public let peak: Float

    /// Frames this observation was computed over, and how many of them sat at the rail (F346).
    ///
    /// Counted rather than inferred, because the clamp below destroys the only other evidence:
    /// `peak` is `min(1, …)`, so a buffer that merely touched full scale and one that was driven
    /// far past it are indistinguishable from here on. Nil means "this build did not measure it",
    /// which is every level constructed before F346 and every hand-built one in a test.
    public let framesMeasured: Int?
    public let framesAtFullScale: Int?

    public init(rms: Float, peak: Float, framesMeasured: Int? = nil, framesAtFullScale: Int? = nil) {
        self.rms = max(0, min(1, rms))
        self.peak = max(0, min(1, peak))
        self.framesMeasured = framesMeasured
        self.framesAtFullScale = framesAtFullScale
    }

    public static let silent = RecordingAudioLevel(rms: 0, peak: 0)
}

/// A plain-language rollup of the health snapshot so the UI can state, in one word, whether the
/// recording is fine — instead of leaving the user to interpret a list of warnings.
public enum RecordingHealthStatus: String, Sendable, Equatable, Codable {
    /// Both channels are being captured and nothing needs attention.
    case good
    /// Something is worth a glance but the recording is not in danger (clipping, or system audio
    /// not detected yet).
    case caution
    /// The recording is at risk right now (a channel stopped delivering audio, or storage is low).
    case atRisk

    /// Severity rank (higher = worse), for folding the worst status reached across a capture.
    var rank: Int {
        switch self {
        case .good: return 0
        case .caution: return 1
        case .atRisk: return 2
        }
    }

    /// Lenient decode (F188). A status this build has never heard of — because a newer bundle wrote
    /// the index — must not throw, because one `dataCorrupted` here fails the decode of the entire
    /// `meetings.json` array. That is the mechanism behind the 2026-08-14 index wipe; F187 softened
    /// its consequence to a read-only library and F190 made the prior generations restorable, but
    /// neither stops the decode from failing. Follows the `MeetingStatus` precedent
    /// (`MeetingStore.swift`), which has always decoded leniently.
    ///
    /// Unknown maps to `.caution`, whose own meaning — "worth a glance but the recording is not in
    /// danger" — is exactly what an unrecognised status tells us. `.good` would hide a genuinely new
    /// risk category; `.atRisk` would raise an alarming banner for something that may be benign.
    /// Lossy: re-saving the index drops the unknown value.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RecordingHealthStatus(rawValue: raw) ?? .caution
    }
}

public enum RecordingHealthWarning: String, Sendable, Equatable, Hashable, Codable {
    case microphoneCaptureStopped
    case systemAudioCaptureStopped
    case systemAudioNotDetected
    case microphoneClipping
    case systemAudioClipping
    case lowStorage
    /// **Decode-only** (F335). F150 warned when the classic WAV `data` field was about to run out;
    /// F302 made long recordings RF64, so nothing emits this any more and the helper that decided
    /// when to was deleted. The case, `RecordingHUD.rank`/`message` and `ContentView`'s branch stay
    /// because health reports saved by older recordings still decode it.
    case approachingLengthLimit

    /// Whether this warning alone puts a recording at risk — it is losing audio, or about to.
    ///
    /// One rule rather than two (F344): `RecordingRiskAnnouncer` answered the same question by
    /// building a throwaway snapshot per warning per tick and asking `overallStatus`, which is the
    /// duplication F278 and F337 were both about. Exhaustive on purpose — a new warning has to
    /// declare which side it is on.
    public var isAtRisk: Bool {
        switch self {
        case .microphoneCaptureStopped, .systemAudioCaptureStopped, .lowStorage:
            return true
        case .systemAudioNotDetected, .microphoneClipping, .systemAudioClipping, .approachingLengthLimit:
            return false
        }
    }
}

public struct RecordingHealthSnapshot: Sendable, Equatable {
    public let microphoneLevel: RecordingAudioLevel
    public let systemAudioLevel: RecordingAudioLevel
    public let availableStorageBytes: Int64?
    public let warnings: [RecordingHealthWarning]

    public init(
        microphoneLevel: RecordingAudioLevel,
        systemAudioLevel: RecordingAudioLevel,
        availableStorageBytes: Int64?,
        warnings: [RecordingHealthWarning]
    ) {
        self.microphoneLevel = microphoneLevel
        self.systemAudioLevel = systemAudioLevel
        self.availableStorageBytes = availableStorageBytes
        self.warnings = warnings
    }

    /// Both channels stopped together — the capture itself stopped, not one device (F292). On the
    /// user's docked lid close this read "Microphone audio stopped arriving. Check the microphone
    /// connection.", which blamed a microphone for a display event.
    public var captureStoppedOnBothChannels: Bool {
        warnings.contains(.microphoneCaptureStopped) && warnings.contains(.systemAudioCaptureStopped)
    }

    /// One-word health rollup derived purely from `warnings`, so the UI does not have to
    /// re-implement the severity logic. A stopped channel or low storage puts the recording at
    /// risk; clipping or not-yet-detected system audio is a caution; anything else is good.
    public var overallStatus: RecordingHealthStatus {
        if warnings.contains(where: \.isAtRisk) { return .atRisk }
        return warnings.isEmpty ? .good : .caution
    }
}

/// A post-meeting rollup folded across the whole capture: which distinct warnings occurred, the worst
/// status reached, per-channel total stale seconds, and whether system audio was ever detected —
/// persisted so a bad recording explains itself rather than being blamed on the model (F58).
public struct RecordingHealthReport: Sendable, Equatable, Codable {
    public let warnings: Set<RecordingHealthWarning>
    public let worstStatus: RecordingHealthStatus
    public let microphoneStaleSeconds: TimeInterval
    public let systemAudioStaleSeconds: TimeInterval
    public let systemAudioEverDetected: Bool

    /// How many frames were examined per channel, and how many were at full scale (F346).
    ///
    /// Four plain `Int?`s rather than a nested struct or a `Float`, and each choice was forced:
    ///
    /// - **`Int`, never `Float`.** `BackupJSONStore` encodes with a plain `JSONEncoder`, which has
    ///   no `nonConformingFloatEncodingStrategy` — so one NaN reaching this field would throw and
    ///   take the whole `meetings.json` write with it. A count cannot be NaN.
    /// - **Flat, not a nested `Codable` struct.** A nested type gets a synthesised decoder that is
    ///   strict about its own non-optional members, so any member added to it later would throw on
    ///   every older report. Flat optionals stay additive forever.
    /// - **`let` with no property default.** This type has a hand-written `init(from:)`, and a
    ///   `let` with no default makes the compiler *force* it to be decoded there. Declared `var`,
    ///   the identical field compiles clean, reaches the wire, and reads back nil — F304's shape,
    ///   one level down. `swiftc -typecheck` does not catch it; only a full compile does.
    ///
    /// Nil means "not measured", which is every report written before F346 — distinct from zero,
    /// which means measured and nothing was at the rail.
    public let microphoneFramesMeasured: Int?
    public let microphoneFramesAtFullScale: Int?
    public let systemAudioFramesMeasured: Int?
    public let systemAudioFramesAtFullScale: Int?

    public init(
        warnings: Set<RecordingHealthWarning>,
        worstStatus: RecordingHealthStatus,
        microphoneStaleSeconds: TimeInterval,
        systemAudioStaleSeconds: TimeInterval,
        systemAudioEverDetected: Bool,
        microphoneFramesMeasured: Int? = nil,
        microphoneFramesAtFullScale: Int? = nil,
        systemAudioFramesMeasured: Int? = nil,
        systemAudioFramesAtFullScale: Int? = nil
    ) {
        self.microphoneFramesMeasured = microphoneFramesMeasured
        self.microphoneFramesAtFullScale = microphoneFramesAtFullScale
        self.systemAudioFramesMeasured = systemAudioFramesMeasured
        self.systemAudioFramesAtFullScale = systemAudioFramesAtFullScale
        self.warnings = warnings
        self.worstStatus = worstStatus
        self.microphoneStaleSeconds = microphoneStaleSeconds
        self.systemAudioStaleSeconds = systemAudioStaleSeconds
        self.systemAudioEverDetected = systemAudioEverDetected
    }

    /// Lenient decode of `warnings` (F188), for the same reason `RecordingHealthStatus` decodes
    /// leniently: a warning case added by a newer bundle must not fail the decode of the whole
    /// `meetings.json` array.
    ///
    /// The leniency has to live here rather than on `RecordingHealthWarning` itself. `Decodable`
    /// cannot express "skip this element", so a lenient initialiser on the enum would still have to
    /// invent a case; decoding the collection as `[String]` and filtering is the only way to drop an
    /// unknown member. Dropping rather than preserving is deliberate: a warning this build cannot
    /// name has no title to render and no explanation to offer, so keeping a placeholder would put
    /// an unlabelled row in the health sheet. Lossy: re-saving the index drops the unknown warning.
    ///
    /// The severity is NOT carried by `worstStatus` on its own, and an earlier version of this
    /// comment wrongly claimed it was. `RecordingHealthAdvisory.message` uses `worstStatus` only as
    /// a gate and derives every word from `warnings`, so a report whose only warning was dropped
    /// rendered no advisory at all — the user saw a clean recording *because* it had been flagged.
    /// That is why `RecordingHealthAdvisory` now states the flagged-but-unexplainable case
    /// explicitly; this decode is only safe together with it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawWarnings = try container.decode([String].self, forKey: .warnings)
        warnings = Set(rawWarnings.compactMap(RecordingHealthWarning.init(rawValue:)))
        worstStatus = try container.decode(RecordingHealthStatus.self, forKey: .worstStatus)
        microphoneStaleSeconds = try container.decode(
            TimeInterval.self, forKey: .microphoneStaleSeconds
        )
        systemAudioStaleSeconds = try container.decode(
            TimeInterval.self, forKey: .systemAudioStaleSeconds
        )
        systemAudioEverDetected = try container.decode(Bool.self, forKey: .systemAudioEverDetected)
        // `try?` as well as `decodeIfPresent` (F346): absent is the ordinary case for every report
        // written before today, and a *malformed* value — a float where an Int belongs, say — must
        // degrade this one field to nil rather than fail the decode of the whole meetings array.
        // That is the same leniency the warnings decode above exists for.
        microphoneFramesMeasured = try? container.decodeIfPresent(Int.self, forKey: .microphoneFramesMeasured)
        microphoneFramesAtFullScale = try? container.decodeIfPresent(Int.self, forKey: .microphoneFramesAtFullScale)
        systemAudioFramesMeasured = try? container.decodeIfPresent(Int.self, forKey: .systemAudioFramesMeasured)
        systemAudioFramesAtFullScale = try? container.decodeIfPresent(Int.self, forKey: .systemAudioFramesAtFullScale)
    }
}

/// Evaluates capture health from a serial stream of audio observations.
public final class RecordingHealthMonitor {
    /// A frame at or above this magnitude is at the rail (F346).
    ///
    /// `32767 / 32768` exactly — a dyadic rational, so float32 holds it with no rounding. It is the
    /// largest magnitude a 16-bit source produces under the usual `/32768` normalisation, so a
    /// full-scale int16 sample lands *on* the floor rather than one ulp under it. Deliberately not
    /// the 0.98 that raises the warning: that one answers "is this worth mentioning", this one
    /// answers "did this frame actually clip", and conflating them is the defect.
    public static let fullScaleFloor: Float = Float(Int16.max) / 32768

    private struct ChannelState {
        var level: RecordingAudioLevel = .silent
        var lastReceivedAt: TimeInterval?
        var lastClippedAt: TimeInterval?
        /// Accumulated only from observations that carried counts, so a mix of measured and
        /// unmeasured buffers reports the measured ones rather than a silent undercount of both.
        var framesMeasured: Int?
        var framesAtFullScale: Int?
    }

    private let startedAt: TimeInterval
    private let initialGracePeriod: TimeInterval
    private let staleAfter: TimeInterval
    private let systemDetectionGracePeriod: TimeInterval
    private let clippingHoldPeriod: TimeInterval
    private let lowStorageThresholdBytes: Int64
    private var microphone = ChannelState()
    private var systemAudio = ChannelState()

    // Accumulated across the capture for the post-meeting report (F58).
    private var seenWarnings: Set<RecordingHealthWarning> = []
    private var worstStatus: RecordingHealthStatus = .good
    private var microphoneStaleSeconds: TimeInterval = 0
    private var systemAudioStaleSeconds: TimeInterval = 0
    private var lastSnapshotTime: TimeInterval?

    public init(
        startedAt: TimeInterval,
        initialGracePeriod: TimeInterval = 4,
        staleAfter: TimeInterval = 3,
        systemDetectionGracePeriod: TimeInterval = 15,
        clippingHoldPeriod: TimeInterval = 3,
        lowStorageThresholdBytes: Int64 = 2_000_000_000
    ) {
        self.startedAt = startedAt
        self.initialGracePeriod = initialGracePeriod
        self.staleAfter = staleAfter
        self.systemDetectionGracePeriod = systemDetectionGracePeriod
        self.clippingHoldPeriod = clippingHoldPeriod
        self.lowStorageThresholdBytes = lowStorageThresholdBytes
    }

    public func receive(
        _ channel: RecordingChannel,
        level: RecordingAudioLevel,
        at time: TimeInterval
    ) {
        switch channel {
        case .microphone:
            update(&microphone, level: level, at: time)
        case .systemAudio:
            update(&systemAudio, level: level, at: time)
        }
    }

    public func snapshot(
        at time: TimeInterval,
        availableStorageBytes: Int64?
    ) -> RecordingHealthSnapshot {
        var warnings: [RecordingHealthWarning] = []
        if time - startedAt >= initialGracePeriod {
            if isStale(microphone, at: time) {
                warnings.append(.microphoneCaptureStopped)
            }
            if systemAudio.lastReceivedAt != nil,
               isStale(systemAudio, at: time) {
                warnings.append(.systemAudioCaptureStopped)
            }
        }
        if systemAudio.lastReceivedAt == nil,
           time - startedAt >= systemDetectionGracePeriod {
            warnings.append(.systemAudioNotDetected)
        }
        if recentlyClipped(microphone, at: time) {
            warnings.append(.microphoneClipping)
        }
        if recentlyClipped(systemAudio, at: time) {
            warnings.append(.systemAudioClipping)
        }
        // F302 retired F150's `.approachingLengthLimit` here: a recording past the classic WAV limit
        // is now written as RF64 and stays readable, so "stop soon so the whole file stays
        // readable" would be asking the user to act on something that is no longer true. The case
        // and its copy remain because saved health reports from older recordings still decode it.
        if let availableStorageBytes,
           availableStorageBytes < lowStorageThresholdBytes {
            warnings.append(.lowStorage)
        }
        let snapshot = RecordingHealthSnapshot(
            microphoneLevel: microphone.level,
            systemAudioLevel: systemAudio.level,
            availableStorageBytes: availableStorageBytes,
            warnings: warnings
        )

        // Fold this snapshot into the running report.
        seenWarnings.formUnion(warnings)
        if snapshot.overallStatus.rank > worstStatus.rank { worstStatus = snapshot.overallStatus }
        if let last = lastSnapshotTime, time > last, time - startedAt >= initialGracePeriod {
            let delta = time - last
            if isStale(microphone, at: time) { microphoneStaleSeconds += delta }
            if systemAudio.lastReceivedAt != nil, isStale(systemAudio, at: time) { systemAudioStaleSeconds += delta }
        }
        lastSnapshotTime = time

        return snapshot
    }

    /// The post-meeting rollup folded across every `snapshot(...)` taken during the capture (F58).
    public func report() -> RecordingHealthReport {
        RecordingHealthReport(
            warnings: seenWarnings,
            worstStatus: worstStatus,
            microphoneStaleSeconds: microphoneStaleSeconds,
            systemAudioStaleSeconds: systemAudioStaleSeconds,
            systemAudioEverDetected: systemAudio.lastReceivedAt != nil,
            microphoneFramesMeasured: microphone.framesMeasured,
            microphoneFramesAtFullScale: microphone.framesAtFullScale,
            systemAudioFramesMeasured: systemAudio.framesMeasured,
            systemAudioFramesAtFullScale: systemAudio.framesAtFullScale
        )
    }

    private func isStale(_ channel: ChannelState, at time: TimeInterval) -> Bool {
        guard let lastReceivedAt = channel.lastReceivedAt else { return true }
        return time - lastReceivedAt > staleAfter
    }

    private func recentlyClipped(_ channel: ChannelState, at time: TimeInterval) -> Bool {
        guard let lastClippedAt = channel.lastClippedAt else { return false }
        return time - lastClippedAt <= clippingHoldPeriod
    }

    private func update(
        _ channel: inout ChannelState,
        level: RecordingAudioLevel,
        at time: TimeInterval
    ) {
        channel.level = level
        channel.lastReceivedAt = time
        if level.peak >= 0.98 {
            channel.lastClippedAt = time
        }
        // The trigger above is unchanged on purpose (F346): a recording that was flagged before
        // still is. What changes is that the evidence now survives alongside it.
        if let measured = level.framesMeasured, let atFullScale = level.framesAtFullScale {
            channel.framesMeasured = (channel.framesMeasured ?? 0) + measured
            channel.framesAtFullScale = (channel.framesAtFullScale ?? 0) + atFullScale
        }
    }
}
