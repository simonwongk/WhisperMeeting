import Foundation

public enum RecordingChannel: Sendable, Equatable {
    case microphone
    case systemAudio
}

public struct RecordingAudioLevel: Sendable, Equatable {
    public let rms: Float
    public let peak: Float

    public init(rms: Float, peak: Float) {
        self.rms = max(0, min(1, rms))
        self.peak = max(0, min(1, peak))
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
}

public enum RecordingHealthWarning: String, Sendable, Equatable, Hashable, Codable {
    case microphoneCaptureStopped
    case systemAudioCaptureStopped
    case systemAudioNotDetected
    case microphoneClipping
    case systemAudioClipping
    case lowStorage
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

    /// One-word health rollup derived purely from `warnings`, so the UI does not have to
    /// re-implement the severity logic. A stopped channel or low storage puts the recording at
    /// risk; clipping or not-yet-detected system audio is a caution; anything else is good.
    public var overallStatus: RecordingHealthStatus {
        let atRisk: Set<RecordingHealthWarning> = [
            .microphoneCaptureStopped,
            .systemAudioCaptureStopped,
            .lowStorage
        ]
        if warnings.contains(where: atRisk.contains) {
            return .atRisk
        }
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

    public init(
        warnings: Set<RecordingHealthWarning>,
        worstStatus: RecordingHealthStatus,
        microphoneStaleSeconds: TimeInterval,
        systemAudioStaleSeconds: TimeInterval,
        systemAudioEverDetected: Bool
    ) {
        self.warnings = warnings
        self.worstStatus = worstStatus
        self.microphoneStaleSeconds = microphoneStaleSeconds
        self.systemAudioStaleSeconds = systemAudioStaleSeconds
        self.systemAudioEverDetected = systemAudioEverDetected
    }
}

/// Evaluates capture health from a serial stream of audio observations.
public final class RecordingHealthMonitor {
    private struct ChannelState {
        var level: RecordingAudioLevel = .silent
        var lastReceivedAt: TimeInterval?
        var lastClippedAt: TimeInterval?
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
            systemAudioEverDetected: systemAudio.lastReceivedAt != nil
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
    }
}
