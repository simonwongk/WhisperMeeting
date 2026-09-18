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
    case anotherBackupIsRunning
    case insufficientSpace(needed: Int64, available: Int64)
    case verificationFailed(String)
    case destinationOverlapsSource

    var errorDescription: String? {
        switch self {
        case let .insufficientSpace(needed, available):
            return "Not enough free space at the backup location: need about \(needed / 1_000_000) MB, \(available / 1_000_000) MB available."
        case let .verificationFailed(path):
            return "A backed-up file failed verification: \(path). The backup was not completed."
        case .anotherBackupIsRunning:
            return "Another backup to this destination is already running. Nothing was changed; try again when it finishes."
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
    /// Prefix for a generation being built. Never a valid generation id, so
    /// `numericDirectories` cannot mistake one for a backup (F191 slice C).
    static let stagingPrefix = ".staging-"

    /// Marker file written into a generation once it is fully copied+verified. A generation without it is
    /// an interrupted/partial run and is never counted or pruned as a real backup (F137).
    static let completionMarker = ".backup-complete"
    /// The one definition of what a backup contains — never the whole Application Support dir
    /// (F137). A list of CANDIDATES, not requirements: a fresh library has no
    /// `replacement-rules.json` and no ledgers until its first save, and demanding them would make
    /// the backup feature fail on a new install, which turns a safety feature into an obstacle.
    ///
    /// Derived from the index stems rather than written out, because writing them out is how two of
    /// the three came to be missing (F191 slice A). The app persists three indexes and F190 gives
    /// each one two siblings; the previous list had one stem with one file and one with none.
    ///
    /// What was wrong, in descending order of how visible it was to a user:
    ///
    /// - `replacement-rules.json` was absent entirely. The backup UI promises indexes and silently
    ///   dropped one of the three.
    /// - Every `.backup.json` was absent, so a restored library had no redundancy behind a single
    ///   decode failure — the redundancy F190 exists to provide.
    /// - Every `.ledger.json` was absent. Checked rather than assumed: this does NOT make a
    ///   restored library read as divergent, because `isDivergent` opens with
    ///   `guard let ledger else { return false }`. The cost is losing divergence detection until
    ///   the next save, not a quarantine on first load.
    static let indexStems = ["meetings", "vocabulary", "replacement-rules"]

    /// Excluded deliberately, and asserted by a test so it stays a decision rather than an
    /// oversight:
    ///
    /// - `meetings.history/` is a short undo window, not an archive (the F190 note says so), and
    ///   copying a rolling buffer into every generation multiplies it by the retain count.
    /// - Install logs and downloaded runtimes are not user data and are re-creatable.
    /// - Quarantined `*.unreadable-*.json` files are evidence of one incident, kept in place by
    ///   `StoreQuarantine` precisely so they sit beside the library they came from.
    static let backedUpEntries: [String] = ["Recordings"] + indexStems.flatMap {
        ["\($0).json", "\($0).backup.json", "\($0).ledger.json"]
    } + ["vocabulary.priority.json"] // F300: which terms are starred; absent until one is.

    /// Back up `source` into `destination/<managedSubfolder>/<now>/`, retaining the newest `retain`
    /// complete generations.
    static func backUp(source: URL, destination: URL, now: Int, retain: Int) throws -> BackupSummary {
        let fileManager = FileManager.default
        guard !pathsOverlap(source, destination) else { throw BackupCoordinatorError.destinationOverlapsSource }

        let backupRoot = destination.appendingPathComponent(managedSubfolder, isDirectory: true)
        try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        // Exclusive for the whole run (F191 slice C). Without it, two backups into one destination
        // destroyed each other's work: a run at the same second-granularity stamp removed the
        // generation directory before writing it, deleting a COMPLETED backup to make room, and the
        // partial-cleanup pass at the end removed every unmarked directory — which is precisely
        // what a concurrently running backup's generation looks like.
        //
        // Refuses rather than failing open. The recovery lease does the opposite, and the
        // difference is which way the fallback is destructive: refusing recovery would brick a
        // library permanently, while refusing a backup costs one retry.
        let lock = BackupLock.acquire(backupRoot: backupRoot)
        guard lock.isHeld else { throw BackupCoordinatorError.anotherBackupIsRunning }
        defer { lock.release() }

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

        // Staged under a unique name, published by rename (F191 slice C).
        //
        // The generation directory used to be created at its final name and cleared first with
        // `try? removeItem`, so a second run at the same stamp deleted the first's COMPLETE
        // generation — the backup the user was relying on — to make room for its own partial one.
        // Now nothing exists at the final name until every file is copied, verified and marked, so
        // a run that dies leaves a staging directory and never a half-built generation.
        let publishedDir = backupRoot.appendingPathComponent(String(now), isDirectory: true)
        let generationDir = backupRoot
            .appendingPathComponent("\(stagingPrefix)\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: generationDir, withIntermediateDirectories: true)
        // Any throw between here and publication leaves staging bytes, never a generation. The
        // cleanup pass below removes them, and it is safe to do so only because the lock is held:
        // any OTHER staging directory is definitionally abandoned, since the holder is the only
        // process that could own one.
        var published = false
        defer { if !published { try? fileManager.removeItem(at: generationDir) } }

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

        // The manifest, then the marker, both while still staged — so the whole evidence set
        // becomes visible at the final name in one rename (F191 slice D).
        //
        // Built from `sourceFiles`, which is exactly the set that got into the generation. A
        // hardlinked (skipped) file shares the previous generation's inode and therefore its
        // contents, so the source hash describes it correctly.
        //
        // The marker stays. A generation written before this has no manifest and must still read
        // as complete — an improvement that made older backups unrestorable would be data loss
        // wearing a feature's clothes.
        try BackupManifest(
            generation: String(now),
            createdAtEpoch: now,
            files: sourceFiles.map {
                .init(relativePath: $0.relativePath, size: $0.size, sha256: $0.contentHash)
            }
        ).write(to: generationDir)
        try Data().write(to: generationDir.appendingPathComponent(completionMarker))

        // Publish. A pre-existing generation at this stamp is replaced only now, after the
        // replacement is known-good: `replaceItemAt` swaps it atomically, so a same-stamp rerun can
        // never leave the user with neither.
        if fileManager.fileExists(atPath: publishedDir.path) {
            _ = try fileManager.replaceItemAt(publishedDir, withItemAt: generationDir)
        } else {
            try fileManager.moveItem(at: generationDir, to: publishedDir)
        }
        published = true

        // Prune old COMPLETE generations (the marker excludes partials), then clear abandoned
        // staging directories. Safe under the lock: no other run can own one.
        let allComplete = completeGenerations(in: backupRoot, fileManager: fileManager)
        let toDrop = BackupRetention.prune(generations: allComplete, policy: .keepLatest(retain))
        // Only what was ACTUALLY removed is reported. This was `try?` with every intended id
        // returned regardless, so a removal that failed — a read-only parent, a file held open —
        // came back in `prunedGenerations` anyway: a return value asserting a disk state it had not
        // reached, which is the same defect as a comment that outlives its code.
        var prunedIDs: [String] = []
        for generation in toDrop {
            let url = backupRoot.appendingPathComponent(generation.id, isDirectory: true)
            do {
                try fileManager.removeItem(at: url)
                prunedIDs.append(generation.id)
            } catch {
                // Not fatal: the backup itself succeeded, and retention is a tidiness policy. The
                // summary simply does not claim it.
                continue
            }
        }
        // Both kinds of leftover, and keeping this sweep is the point rather than an accident.
        //
        // My first version of this change dropped the unmarked-numeric sweep entirely, on the
        // grounds that staged publication means this run never creates one. An existing F137 test
        // caught it: a build from before staged publication could have died mid-run and left a
        // partial at the final name, and nothing would ever clear it. The old sweep was correct in
        // INTENT and unsafe only because it ran without a lock — a concurrent run's in-flight
        // generation is also unmarked. So it is secured, not removed: under the lock, no other run
        // can own either kind, and this run's own generation is already published by now.
        let leftovers = stagingDirectories(in: backupRoot, fileManager: fileManager)
            + partialGenerations(in: backupRoot, fileManager: fileManager).map {
                backupRoot.appendingPathComponent($0, isDirectory: true)
            }
        for leftover in leftovers {
            try? fileManager.removeItem(at: leftover)
        }

        return BackupSummary(
            generation: String(now),
            copied: copied,
            skipped: skipped,
            verified: true,
            prunedGenerations: prunedIDs
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
                // Nor the manifest: it describes the generation's user data, so including it in
                // the next generation's plan would make it a file that must describe itself.
                if url.lastPathComponent == BackupManifest.fileName { continue }
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

    /// Directories left behind by a run that did not reach publication. Under the backup lock,
    /// every one of these is abandoned by definition — the lock holder is the only process that
    /// could own one — which is what makes removing them safe rather than a race against a
    /// concurrent run. That race is exactly what the old unmarked-directory sweep was.
    private static func stagingDirectories(in backupRoot: URL, fileManager: FileManager) -> [URL] {
        let names = (try? fileManager.contentsOfDirectory(atPath: backupRoot.path)) ?? []
        return names
            .filter { $0.hasPrefix(stagingPrefix) }
            .map { backupRoot.appendingPathComponent($0, isDirectory: true) }
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

    /// How much of a file is held in memory at once while hashing it.
    ///
    /// 1 MiB: large enough that a 4 GB recording costs ~4,000 reads rather than a syscall per page,
    /// small enough that it is irrelevant beside the app's own footprint.
    static let hashChunkByteCount = 1 << 20

    /// Streams a file through SHA-256 (F191 slice B).
    ///
    /// Was `SHA256.hash(data: try Data(contentsOf: url))`, which reads the whole file into memory
    /// to hash it. The backup hashes every changed file to verify the copy, and the files it exists
    /// to protect are multi-gigabyte recordings — so the verification step was the one most likely
    /// to fail on exactly the library that needed backing up most.
    ///
    /// The read is injected so the chunking itself is observable. "Memory did not grow" is not
    /// something a test can assert honestly; how many times the reader was asked, and for how much,
    /// is.
    static func sha256(
        of url: URL,
        read: (FileHandle, Int) throws -> Data? = { try $0.read(upToCount: $1) }
    ) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try read(handle, hashChunkByteCount), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
