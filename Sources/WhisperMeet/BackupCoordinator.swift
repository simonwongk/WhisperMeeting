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
    case destinationOverlapsSource

    var errorDescription: String? {
        switch self {
        case let .insufficientSpace(needed, available):
            return "Not enough free space at the backup location: need about \(needed / 1_000_000) MB, \(available / 1_000_000) MB available."
        case let .verificationFailed(path):
            return "A backed-up file failed verification: \(path). The backup was not completed."
        case .destinationOverlapsSource:
            return "Choose a backup folder outside your meeting library — the backup location can't be the library or a folder inside it."
        }
    }
}

/// Backs the meeting library up to a chosen destination as timestamped generation snapshots, wiring the
/// tested `BackupPlan` / `BackupRetention` / `BackupVerification` core (F75/F90). Safety (F137):
/// generations live only under a dedicated managed subfolder so pruning can never touch the user's other
/// folders; each generation is marked `.complete` and only marked ones are counted/pruned (partials are
/// cleaned up); the destination may not overlap the source; and only the meeting library — not installed
/// models/runtimes — is copied. A file unchanged since the previous generation is hardlinked; a
/// changed/new file is copied and hash-verified. The source is only ever read.
enum BackupCoordinator {
    /// Managed subfolder (inside the user's chosen destination) that holds all backup generations. Only
    /// this subtree is ever scanned or pruned — never the chosen folder's other contents (F137).
    static let managedSubfolder = "WhisperMeet Backups"
    /// Marker file written into a generation once it is fully copied+verified. A generation without it is
    /// an interrupted/partial run and is never counted or pruned as a real backup (F137).
    static let completionMarker = ".backup-complete"
    /// The library entries that are backed up — never the whole Application Support dir (F137).
    static let backedUpEntries = ["Recordings", "meetings.json", "vocabulary.json"]

    /// Back up `source` into `destination/<managedSubfolder>/<now>/`, retaining the newest `retain`
    /// complete generations.
    static func backUp(source: URL, destination: URL, now: Int, retain: Int) throws -> BackupSummary {
        let fileManager = FileManager.default
        guard !pathsOverlap(source, destination) else { throw BackupCoordinatorError.destinationOverlapsSource }

        let backupRoot = destination.appendingPathComponent(managedSubfolder, isDirectory: true)
        try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        let sourceFiles = try descriptors(of: source, includingTopLevel: backedUpEntries)

        // Only COMPLETE generations are valid prior snapshots to hardlink from.
        let existing = completeGenerations(in: backupRoot, fileManager: fileManager)
        let previousDir = existing.max(by: { $0.createdAtEpoch < $1.createdAtEpoch })
            .map { backupRoot.appendingPathComponent($0.id, isDirectory: true) }
        let previousFiles = previousDir.map { (try? descriptors(of: $0, includingTopLevel: nil)) ?? [] } ?? []
        let plan = BackupPlan.compute(source: sourceFiles, destination: previousFiles)

        // Pre-copy free-space check for the bytes that will actually be copied. Only reject on a
        // credible positive reading below the need — see `shouldRejectForSpace` (F90 audit fix).
        let bytesToCopy = plan.filter { $0.action == .copy }.reduce(Int64(0)) { $0 + $1.file.size }
        let available = availableCapacity(at: backupRoot)
        if shouldRejectForSpace(available: available, needed: bytesToCopy) {
            throw BackupCoordinatorError.insufficientSpace(needed: bytesToCopy, available: available ?? 0)
        }

        let generationDir = backupRoot.appendingPathComponent(String(now), isDirectory: true)
        // A leftover dir at this exact stamp (e.g. a prior partial) is replaced, not merged.
        try? fileManager.removeItem(at: generationDir)
        try fileManager.createDirectory(at: generationDir, withIntermediateDirectories: true)

        var copied = 0
        var skipped = 0
        for item in plan {
            let sourceURL = source.appendingPathComponent(item.file.relativePath)
            let destURL = generationDir.appendingPathComponent(item.file.relativePath)
            try fileManager.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch item.action {
            case .skip:
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

        // Mark complete only after every file copied and verified.
        try Data().write(to: generationDir.appendingPathComponent(completionMarker))

        // Prune old COMPLETE generations (the marker excludes partials), then clean up any leftover
        // partial (unmarked) generation directories so they never masquerade as backups.
        let allComplete = completeGenerations(in: backupRoot, fileManager: fileManager)
        let toDrop = BackupRetention.prune(generations: allComplete, policy: .keepLatest(retain))
        for generation in toDrop {
            try? fileManager.removeItem(at: backupRoot.appendingPathComponent(generation.id, isDirectory: true))
        }
        for partial in partialGenerations(in: backupRoot, fileManager: fileManager) {
            try? fileManager.removeItem(at: backupRoot.appendingPathComponent(partial, isDirectory: true))
        }

        return BackupSummary(
            generation: String(now),
            copied: copied,
            skipped: skipped,
            verified: true,
            prunedGenerations: toDrop.map(\.id)
        )
    }

    /// True when `a` and `b` are the same directory or one contains the other — used to refuse backing up
    /// into the library itself or a child/parent of it (F137).
    static func pathsOverlap(_ a: URL, _ b: URL) -> Bool {
        let pa = a.standardizedFileURL.path
        let pb = b.standardizedFileURL.path
        if pa == pb { return true }
        return pb.hasPrefix(pa + "/") || pa.hasPrefix(pb + "/")
    }

    /// Enumerate the given top-level entries (or the whole tree when `includingTopLevel` is nil, used for
    /// reading a prior generation) into `[BackupFile]` (relative path, size, SHA-256).
    private static func descriptors(of root: URL, includingTopLevel entries: [String]?) throws -> [BackupFile] {
        let fileManager = FileManager.default
        let rootPath = root.standardizedFileURL.path
        var result: [BackupFile] = []

        func addTree(_ base: URL) throws {
            guard let enumerator = fileManager.enumerator(
                at: base, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
            ) else { return }
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true else { continue }
                let full = url.standardizedFileURL.path
                guard full.hasPrefix(rootPath + "/") else { continue }
                // Never back up the backup marker itself when reading a prior generation.
                if url.lastPathComponent == completionMarker { continue }
                result.append(BackupFile(
                    relativePath: String(full.dropFirst(rootPath.count + 1)),
                    size: Int64(values.fileSize ?? 0),
                    contentHash: try sha256(of: url)
                ))
            }
        }

        if let entries {
            for entry in entries {
                let url = root.appendingPathComponent(entry)
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    try addTree(url)
                } else {
                    let values = try url.resourceValues(forKeys: [.fileSizeKey])
                    result.append(BackupFile(relativePath: entry, size: Int64(values.fileSize ?? 0), contentHash: try sha256(of: url)))
                }
            }
        } else {
            try addTree(root)
        }
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    /// Integer-named generation directories under the managed backup root that carry the completion
    /// marker (i.e. real, finished backups).
    private static func completeGenerations(in backupRoot: URL, fileManager: FileManager) -> [BackupGeneration] {
        numericDirectories(in: backupRoot, fileManager: fileManager).compactMap { (name, url) in
            guard fileManager.fileExists(atPath: url.appendingPathComponent(completionMarker).path),
                  let epoch = Int(name) else { return nil }
            return BackupGeneration(id: name, createdAtEpoch: epoch)
        }
    }

    /// Integer-named generation directories under the managed backup root that LACK the completion marker
    /// (interrupted/partial runs to clean up).
    private static func partialGenerations(in backupRoot: URL, fileManager: FileManager) -> [String] {
        numericDirectories(in: backupRoot, fileManager: fileManager).compactMap { (name, url) in
            fileManager.fileExists(atPath: url.appendingPathComponent(completionMarker).path) ? nil : name
        }
    }

    private static func numericDirectories(in backupRoot: URL, fileManager: FileManager) -> [(String, URL)] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: backupRoot, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return entries.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  Int(url.lastPathComponent) != nil else { return nil }
            return (url.lastPathComponent, url)
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Whether to reject a backup for lack of space. Rejects ONLY on a credible positive capacity
    /// reading below the need; a nil (unknown) or non-positive reading — which macOS returns for
    /// `volumeAvailableCapacityForImportantUsage` on some volumes — never blocks (F90 audit fix).
    static func shouldRejectForSpace(available: Int64?, needed: Int64) -> Bool {
        guard needed > 0, let available, available > 0 else { return false }
        return available < needed
    }

    private static func availableCapacity(at url: URL) -> Int64? {
        let probe = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        return (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }
}
