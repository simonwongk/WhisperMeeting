import Foundation

/// A file descriptor for backup planning — content is identified by hash, never read here (F75).
public struct BackupFile: Sendable, Equatable {
    public let relativePath: String
    public let size: Int64
    public let contentHash: String

    public init(relativePath: String, size: Int64, contentHash: String) {
        self.relativePath = relativePath
        self.size = size
        self.contentHash = contentHash
    }
}

public enum BackupAction: Sendable, Equatable {
    case copy // new or changed
    case skip // already current at the destination
}

public struct BackupItem: Sendable, Equatable {
    public let file: BackupFile
    public let action: BackupAction
}

/// Decides which source files need copying to a destination (same relative path + same hash ⇒ skip).
public enum BackupPlan {
    public static func compute(source: [BackupFile], destination: [BackupFile]) -> [BackupItem] {
        let destinationByPath = Dictionary(destination.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        return source.map { file in
            if let existing = destinationByPath[file.relativePath], existing.contentHash == file.contentHash {
                return BackupItem(file: file, action: .skip)
            }
            return BackupItem(file: file, action: .copy)
        }
    }

    /// How many bytes this plan will actually need to WRITE, given whether the destination volume
    /// supports hard links (F532).
    ///
    /// A `.copy` item always costs its full size — it is new or changed, so it is always written.
    /// A `.skip` item costs nothing when hard links are supported: it becomes a link sharing the
    /// previous generation's inode, using no additional space. But exFAT, FAT32, and most SMB
    /// mounts refuse hard links outright, and on those volumes every `.skip` item falls back to an
    /// independent verified copy — the same bytes on disk as a `.copy` item. A free-space check
    /// that only ever counted `.copy` bytes would pass a run that then runs out of room midway
    /// through what it thought were "free" skips.
    public static func bytesNeeded(for plan: [BackupItem], hardLinksSupported: Bool) -> Int64 {
        plan.reduce(Int64(0)) { partial, item in
            switch item.action {
            case .copy:
                return partial + item.file.size
            case .skip:
                return partial + (hardLinksSupported ? 0 : item.file.size)
            }
        }
    }
}

public struct BackupGeneration: Sendable, Equatable {
    public let id: String
    public let createdAtEpoch: Int

    public init(id: String, createdAtEpoch: Int) {
        self.id = id
        self.createdAtEpoch = createdAtEpoch
    }
}

public enum BackupRetentionPolicy: Sendable, Equatable {
    case keepLatest(Int)
    case keepWithinDays(Int, now: Int)
}

/// Decides which destination generations to prune under a retention policy. Returns the generations
/// to DROP; never touches the source.
public enum BackupRetention {
    public static func prune(generations: [BackupGeneration], policy: BackupRetentionPolicy) -> [BackupGeneration] {
        let newestFirst = generations.sorted { $0.createdAtEpoch > $1.createdAtEpoch }
        switch policy {
        case let .keepLatest(count):
            return Array(newestFirst.dropFirst(max(0, count)))
        case let .keepWithinDays(days, now):
            let cutoff = now - days * 86_400
            return newestFirst.filter { $0.createdAtEpoch < cutoff }
        }
    }
}

/// Post-copy integrity: the copied file's hash must match what was expected.
public enum BackupVerification {
    public static func succeeded(expectedHash: String, actualHash: String) -> Bool {
        expectedHash == actualHash
    }
}
