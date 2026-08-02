import CryptoKit
import Foundation
import WhisperCore

/// Result of one backup run.
struct BackupSummary: Sendable, Equatable {
    let generation: String
    let copied: Int
    let skipped: Int
    let verified: Bool
    let prunedGenerations: [String]
}

enum BackupCoordinatorError: LocalizedError {
    case insufficientSpace(needed: Int64, available: Int64)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .insufficientSpace(needed, available):
            return "Not enough free space at the backup location: need about \(needed / 1_000_000) MB, \(available / 1_000_000) MB available."
        case let .verificationFailed(path):
            return "A backed-up file failed verification: \(path). The backup was not completed."
        }
    }
}

/// Backs the meeting library up to a chosen destination as timestamped generation snapshots, wiring the
/// tested `BackupPlan` / `BackupRetention` / `BackupVerification` core (F75). Each run writes a new
/// generation directory; a file unchanged since the previous generation is hardlinked (not re-copied),
/// a changed/new file is copied and hash-verified. The source is only ever read — never modified or
/// deleted — honoring the recording-is-source-of-truth invariant (F90).
enum BackupCoordinator {
    /// Back up `source` into `destination/<now>/`, retaining the newest `retain` generations.
    static func backUp(source: URL, destination: URL, now: Int, retain: Int) throws -> BackupSummary {
        let fileManager = FileManager.default
        let sourceFiles = try descriptors(of: source)

        // Descriptors of the most recent existing generation, so unchanged files can skip.
        let existing = existingGenerations(in: destination, fileManager: fileManager)
        let previousDir = existing.max(by: { $0.createdAtEpoch < $1.createdAtEpoch })
            .map { destination.appendingPathComponent($0.id, isDirectory: true) }
        let previousFiles = previousDir.map { (try? descriptors(of: $0)) ?? [] } ?? []
        let plan = BackupPlan.compute(source: sourceFiles, destination: previousFiles)

        // Pre-copy free-space check for the bytes that will actually be copied.
        let bytesToCopy = plan.filter { $0.action == .copy }.reduce(Int64(0)) { $0 + $1.file.size }
        if let available = availableCapacity(at: destination), available < bytesToCopy {
            throw BackupCoordinatorError.insufficientSpace(needed: bytesToCopy, available: available)
        }

        let generationDir = destination.appendingPathComponent(String(now), isDirectory: true)
        try fileManager.createDirectory(at: generationDir, withIntermediateDirectories: true)

        var copied = 0
        var skipped = 0
        for item in plan {
            let sourceURL = source.appendingPathComponent(item.file.relativePath)
            let destURL = generationDir.appendingPathComponent(item.file.relativePath)
            try fileManager.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch item.action {
            case .skip:
                // Unchanged since the previous generation: hardlink from it so no bytes are re-copied,
                // yet this generation is still a complete snapshot.
                if let previousDir {
                    try fileManager.linkItem(at: previousDir.appendingPathComponent(item.file.relativePath), to: destURL)
                } else {
                    try fileManager.copyItem(at: sourceURL, to: destURL)
                }
                skipped += 1
            case .copy:
                try fileManager.copyItem(at: sourceURL, to: destURL)
                guard BackupVerification.succeeded(expectedHash: item.file.contentHash, actualHash: try sha256(of: destURL)) else {
                    throw BackupCoordinatorError.verificationFailed(item.file.relativePath)
                }
                copied += 1
            }
        }

        // Prune old generations (including the one just written in the candidate set).
        let allGenerations = existingGenerations(in: destination, fileManager: fileManager)
        let toDrop = BackupRetention.prune(generations: allGenerations, policy: .keepLatest(retain))
        for generation in toDrop {
            try? fileManager.removeItem(at: destination.appendingPathComponent(generation.id, isDirectory: true))
        }

        return BackupSummary(
            generation: String(now),
            copied: copied,
            skipped: skipped,
            verified: true,
            prunedGenerations: toDrop.map(\.id)
        )
    }

    /// Enumerate a directory tree into `[BackupFile]` (relative path, size, SHA-256). Directories and
    /// unreadable entries are skipped.
    private static func descriptors(of root: URL) throws -> [BackupFile] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return [] }
        var result: [BackupFile] = []
        let rootPath = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(rootPath + "/") else { continue }
            let relativePath = String(full.dropFirst(rootPath.count + 1))
            result.append(BackupFile(
                relativePath: relativePath,
                size: Int64(values.fileSize ?? 0),
                contentHash: try sha256(of: url)
            ))
        }
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    /// Existing generation directories (named by their integer epoch) at a destination.
    private static func existingGenerations(in destination: URL, fileManager: FileManager) -> [BackupGeneration] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return entries.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let epoch = Int(url.lastPathComponent) else { return nil }
            return BackupGeneration(id: url.lastPathComponent, createdAtEpoch: epoch)
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func availableCapacity(at url: URL) -> Int64? {
        let probe = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        return (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }
}
