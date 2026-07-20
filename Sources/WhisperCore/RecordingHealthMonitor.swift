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

/// A high-frequency snapshot of both channels' loudness, pushed to the UI faster than the
/// once-per-second health snapshot so the live volume bar feels responsive. Pure data only —
/// warnings and storage checks stay on the health-snapshot path.
public struct RecordingLevels: Sendable, Equatable {
    public let microphone: RecordingAudioLevel
    public let systemAudio: RecordingAudioLevel

    public init(microphone: RecordingAudioLevel, systemAudio: RecordingAudioLevel) {
        self.microphone = microphone
        self.systemAudio = systemAudio
    }

    public static let silent = RecordingLevels(microphone: .silent, systemAudio: .silent)

    /// Loudness of whichever channel is currently loudest — drives the combined "someone is
    /// talking" volume bar.
    public var combinedPeak: Float { max(microphone.peak, systemAudio.peak) }
    public var combinedRMS: Float { max(microphone.rms, systemAudio.rms) }
}

/// A plain-language rollup of the health snapshot so the UI can state, in one word, whether the
/// recording is fine — instead of leaving the user to interpret a list of warnings.
public enum RecordingHealthStatus: Sendable, Equatable {
    /// Both channels are being captured and nothing needs attention.
    case good
    /// Something is worth a glance but the recording is not in danger (clipping, or system audio
    /// not detected yet).
    case caution
    /// The recording is at risk right now (a channel stopped delivering audio, or storage is low).
    case atRisk
}

public enum RecordingHealthWarning: Sendable, Equatable, Hashable {
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
        return RecordingHealthSnapshot(
            microphoneLevel: microphone.level,
            systemAudioLevel: systemAudio.level,
            availableStorageBytes: availableStorageBytes,
            warnings: warnings
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
