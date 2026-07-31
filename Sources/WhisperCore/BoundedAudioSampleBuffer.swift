public enum DictationCaptureLimits {
    public static let sampleRate = 16_000
    public static let maximumDurationSeconds = 120
    public static let maximumSampleCount = sampleRate * maximumDurationSeconds
}

public struct BoundedAudioSampleBuffer: Sendable {
    public let capacity: Int
    public private(set) var samples: [Float] = []

    public init(capacity: Int) {
        self.capacity = capacity
    }

    public mutating func append(contentsOf chunk: [Float]) {
        let remaining = max(0, capacity - samples.count)
        guard remaining > 0 else { return }
        samples.append(contentsOf: chunk.prefix(remaining))
    }

    public mutating func removeAll(keepingCapacity: Bool = false) {
        samples.removeAll(keepingCapacity: keepingCapacity)
    }
}
