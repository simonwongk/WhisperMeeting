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

enum BackupCoordinatorError: LocalizedError, Equatable {
    case anotherBackupIsRunning
    /// The backup lock could not even be attempted or held, for a reason that is NOT another
    /// backup running (F559): a read-only remount, a permissions change, a directory sitting where
    /// the lock file goes, too many open files. Carries the destination and `strerror(errno)` so
    /// the message names the actual reason instead of telling the user to wait out contention that
    /// was never happening.
    case lockUnavailable(destination: String, reason: String)
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
        case let .lockUnavailable(destination, reason):
            return "This backup location can't be locked for writing (\(reason)): \(destination). Nothing was changed."
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
/// models/runtimes — is copied. A file unchanged since the previous generation is hardlinked when the
/// destination volume supports it, and falls back to a hash-verified copy otherwise — exFAT, FAT32, and
/// most SMB mounts refuse hard links outright (F532). A changed/new file is always copied and
/// hash-verified. The source is only ever read.
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
    /// - Every `.ledger.json` was absent. That alone does not make a restored library read as
    ///   divergent, because `isDivergent` opens with `guard let ledger else { return false }` —
    ///   but only when no ledger is there at all. Restoring such a backup used to leave the LIVE
    ///   ledger beside the restored index, which is exactly a ledger contradicting its primary,
    ///   and the library opened read-only (F463). The restore now sets the live lineage aside
    ///   (`BackupRestorePlan.wouldSetAside`), so the cost is back to losing divergence detection
    ///   until the next save.
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
        let files = indexFiles(of: $0)
        return [files.primary] + files.lineage
    } + ["vocabulary.priority.json"] // F300: which terms are starred; absent until one is.

    /// The files one index is kept in: the index itself, and the previous generation and ledger
    /// F190 keeps beside it. The two `lineage` files describe the primary they sit next to, so a
    /// restore that replaces the primary takes its lineage from the backup too, or sets the live
    /// lineage aside where the backup has none (F463).
    static func indexFiles(of stem: String) -> (primary: String, lineage: [String]) {
        ("\(stem).json", ["\(stem).backup.json", "\(stem).ledger.json"])
    }

    /// Back up `source` into `destination/<managedSubfolder>/<now>/`, retaining the newest `retain`
    /// complete generations.
    ///
    /// `beforeProcessingForTesting` is a seam for F504's test only (nil in production, called with
    /// each item's relative path right before it is copied or hardlinked): the up-front hashing
    /// pass below runs once for the whole library before any copying starts, so mutating a file
    /// from this hook deterministically reproduces "the source changed after being hashed, before
    /// being copied" with no clock and no real concurrent writer.
    static func backUp(
        source: URL, destination: URL, now: Int, retain: Int,
        beforeProcessingForTesting: ((String) -> Void)? = nil,
        // Seam (real `FileManager.linkItem` in production): what a hard link between two paths
        // does. A test must not depend on the host having an exFAT/FAT/SMB volume to write to, so
        // it injects a link that throws the way `linkItem` does there (ENOTSUP/EPERM/EXDEV) — or
        // one that succeeds by copying, to model a destination that supports links on any host.
        // The SAME function is used by the per-file `.skip` link and by `probeHardLinkSupport`
        // (F652), so a test that makes links fail makes the space check see it too.
        linkItem: (URL, URL) throws -> Void = { try FileManager.default.linkItem(at: $0, to: $1) },
        // Seam (the real volume reading in production): free bytes at the backup location, or nil
        // when unknown. Lets a test give the space check a known number instead of whatever the
        // host's temp volume happens to have (F652).
        freeSpace: (URL) -> Int64? = { BackupCoordinator.availableCapacity(at: $0) }
    ) throws -> BackupSummary {
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
        guard lock.isHeld else {
            // Only real contention (EWOULDBLOCK) is "another backup is already running" (F559).
            // Every other reason `acquire` could not hold the lock — the path blocked by a
            // directory, a read-only remount, a permissions change — gets its own error naming
            // what actually happened, because telling the user to wait out a backup that was never
            // running just wastes their time.
            switch lock.unavailableReason {
            case .contended, nil:
                throw BackupCoordinatorError.anotherBackupIsRunning
            case let .unavailable(_, message):
                throw BackupCoordinatorError.lockUnavailable(destination: backupRoot.path, reason: message)
            }
        }
        defer { lock.release() }

        let sourceFiles = try descriptors(of: source, includingTopLevel: backedUpEntries)

        // Only COMPLETE generations are valid prior snapshots to hardlink from.
        let existing = completeGenerations(in: backupRoot, fileManager: fileManager)
        let previousDir = existing.max(by: { $0.createdAtEpoch < $1.createdAtEpoch })
            .map { backupRoot.appendingPathComponent($0.id, isDirectory: true) }
        let previousFiles = previousDir.map { (try? descriptors(of: $0, includingTopLevel: nil)) ?? [] } ?? []
        let plan = BackupPlan.compute(source: sourceFiles, destination: previousFiles)

        // Probed once per run rather than discovered file-by-file (F532): exFAT, FAT32, and most
        // SMB mounts refuse hard links outright, in which case every `.skip` item below falls back
        // to a real, space-costing copy. The free-space check has to know that BEFORE the run
        // starts — a check that only ever counted `.copy` bytes would pass a run that then runs
        // out of room partway through what it thought were free skips.
        let hardLinksSupported = probeHardLinkSupport(in: backupRoot, fileManager: fileManager, linkItem: linkItem)

        // Pre-copy free-space check for the bytes that will actually be written. Only reject on a
        // credible positive reading below the need — see `shouldRejectForSpace` (F90 audit fix).
        let bytesToCopy = BackupPlan.bytesNeeded(for: plan, hardLinksSupported: hardLinksSupported)
        let available = freeSpace(backupRoot)
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
        // Overrides `sourceFiles`' up-front hash AND size for the manifest, for exactly the files
        // this run copied and re-hashed post-copy (F504, F651): every `.copy` entry, and any `.skip`
        // entry whose hard link failed and fell back to a copy (F532). A `.skip` entry that WAS
        // hard-linked shares the previous generation's inode and is never re-read, so its up-front
        // hash and size still describe it.
        var copiedContent: [String: CopiedFile] = [:]
        for item in plan {
            beforeProcessingForTesting?(item.file.relativePath)
            let sourceURL = source.appendingPathComponent(item.file.relativePath)
            let destURL = generationDir.appendingPathComponent(item.file.relativePath)
            try fileManager.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch item.action {
            case .skip:
                if let previousDir {
                    do {
                        try linkItem(previousDir.appendingPathComponent(item.file.relativePath), destURL)
                    } catch {
                        // Hard links are unavailable on this destination (exFAT, FAT32, most SMB
                        // mounts) or this one link failed for some other reason (F532). Either
                        // way, the file still has to land, so fall back to the same verified copy
                        // a `.copy` item gets — from SOURCE, not from the previous generation, so
                        // the post-copy re-hash-against-source in `copyAndVerify` guards this
                        // fallback against the very same mid-run write race F504 fixed for
                        // `.copy` items. `linkItem` can leave nothing or a partial file behind
                        // depending on where it failed; clear the target first so the copy always
                        // starts from empty.
                        try? fileManager.removeItem(at: destURL)
                        copiedContent[item.file.relativePath] = try Self.copyAndVerify(
                            from: sourceURL, to: destURL, relativePath: item.file.relativePath, fileManager: fileManager
                        )
                    }
                } else {
                    try fileManager.copyItem(at: sourceURL, to: destURL)
                }
                skipped += 1
            case .copy:
                copiedContent[item.file.relativePath] = try Self.copyAndVerify(
                    from: sourceURL, to: destURL, relativePath: item.file.relativePath, fileManager: fileManager
                )
                copied += 1
            }
        }

        // The manifest, then the marker, both while still staged — so the whole evidence set
        // becomes visible at the final name in one rename (F191 slice D).
        //
        // Built from `sourceFiles`, which is exactly the set that got into the generation — except
        // that every file this run COPIED (each `.copy` entry, and each `.skip` entry that fell back
        // to a copy) takes its hash AND its size from `copiedContent`: what `copyAndVerify`
        // actually measured on the bytes it wrote, not what `descriptors(of:)` measured minutes
        // earlier at the top of this run (F504, F651). Taking only the hash from the fresh
        // measurement was the F651 defect — a file that changed mid-run got its new hash beside its
        // old size, and the generation reported verified and then failed its own check. A
        // hardlinked (skipped) file shares the previous generation's inode and therefore its
        // contents, so the up-front hash and size still describe it correctly.
        //
        // The marker stays. A generation written before this has no manifest and must still read
        // as complete — an improvement that made older backups unrestorable would be data loss
        // wearing a feature's clothes.
        try BackupManifest(
            generation: String(now),
            createdAtEpoch: now,
            files: sourceFiles.map { file in
                if let copied = copiedContent[file.relativePath] {
                    return .init(relativePath: file.relativePath, size: copied.size, sha256: copied.sha256)
                }
                return .init(relativePath: file.relativePath, size: file.size, sha256: file.contentHash)
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
        try hashAndCount(of: url, read: read).sha256
    }

    /// The SHA-256 of a file and the number of bytes that hash covers, from ONE pass (F651).
    ///
    /// The size is counted from the same chunks the hasher consumed, not `stat`ed before or after,
    /// so the two cannot describe different bytes. That is the whole point: the backup's manifest
    /// records a size beside every hash, and a size measured at a different moment from the hash is
    /// how a "verified" generation came to fail its own check.
    static func hashAndCount(
        of url: URL,
        read: (FileHandle, Int) throws -> Data? = { try $0.read(upToCount: $1) }
    ) throws -> (sha256: String, byteCount: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount: Int64 = 0
        while let chunk = try read(handle, hashChunkByteCount), !chunk.isEmpty {
            hasher.update(data: chunk)
            byteCount += Int64(chunk.count)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), byteCount)
    }

    /// What `copyAndVerify` measured about the bytes it put at the destination (F651).
    struct CopiedFile: Equatable, Sendable {
        /// SHA-256 of the destination, which `copyAndVerify` has already checked equals the
        /// source's at the moment after the copy.
        let sha256: String
        /// Size of those same bytes. The manifest must record THIS beside `sha256`, never the size
        /// the up-front scan saw: a file that changed between the scan and its own turn has a new
        /// size as well as a new hash, and pairing the old size with the new hash produced a
        /// generation that reported verified and then failed "Wrong size in this backup".
        let size: Int64
    }

    /// Copies `sourceURL` to `destURL` and verifies the copy against a hash of the source taken
    /// immediately AFTER the copy — never against the hash `descriptors(of:)` computed at the very
    /// start of the run, which can be minutes stale by the time a given file's turn comes on a real
    /// library (F504). A mismatch there does not mean the copy is corrupt: it means the source
    /// changed between that up-front scan and this file's copy, which on a real library is
    /// `meetings.json` being saved — atomically replaced — by a debounced write, or a batch
    /// transcription finishing, while the backup is still hashing everything else.
    ///
    /// Retries once after `retryDelay` — the production default is
    /// `MeetingStore.defaultTranscriptWriteDebounce`, exactly how long a pending debounced save can
    /// still be in flight for — so a save that lands mid-copy is given the time it needs to settle
    /// before this is treated as a failure. Still throws `verificationFailed` if the destination and
    /// a freshly-read source disagree twice: at that point either the source is being written
    /// continuously or the copy itself is corrupt, and either way the whole backup must still
    /// refuse rather than report success over mismatched bytes (`fileManager`/`retryDelay`/`sleep`
    /// are seams so the F504 tests can drive the retry without a real half-second wait).
    ///
    /// Returns the hash AND the size of the bytes now at `destURL`, measured in one pass (F651), so
    /// the caller can record a manifest entry whose size and hash describe the same bytes.
    static func copyAndVerify(
        from sourceURL: URL,
        to destURL: URL,
        relativePath: String,
        fileManager: FileManager = .default,
        retryDelay: TimeInterval = MeetingStore.defaultTranscriptWriteDebounce,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        // Test-only seam (nil in production): fires right after each attempt's copy, before either
        // hash is read. The genuine race this guards is a source write landing in the sub-millisecond
        // window between `copyItem` finishing and the immediate re-hash of the source below — too
        // narrow to hit deterministically from a test — so this is what F504's tests use to force
        // that same mismatch on demand, on whichever attempt they choose.
        afterCopyForTesting: ((Int) -> Void)? = nil
    ) throws -> CopiedFile {
        let maxAttempts = 2
        for attempt in 1...maxAttempts {
            if attempt > 1 {
                try? fileManager.removeItem(at: destURL)
                sleep(retryDelay)
            }
            try fileManager.copyItem(at: sourceURL, to: destURL)
            afterCopyForTesting?(attempt)
            let dest = try hashAndCount(of: destURL)
            let sourceHashNow = try sha256(of: sourceURL)
            if BackupVerification.succeeded(expectedHash: sourceHashNow, actualHash: dest.sha256) {
                return CopiedFile(sha256: dest.sha256, size: dest.byteCount)
            }
        }
        throw BackupCoordinatorError.verificationFailed(relativePath)
    }

    /// Whether to reject a backup for lack of space. Rejects ONLY on a credible positive capacity
    /// reading below the need; a nil (unknown) or non-positive reading — which macOS returns for
    /// `volumeAvailableCapacityForImportantUsage` on some volumes — never blocks (F90 audit fix).
    static func shouldRejectForSpace(available: Int64?, needed: Int64) -> Bool {
        guard needed > 0, let available, available > 0 else { return false }
        return available < needed
    }

    static func availableCapacity(at url: URL) -> Int64? {
        let probe = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        return (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    /// Name prefix of the throwaway files the hard-link probe writes under the backup root. Dotted
    /// and non-numeric, so `numericDirectories` can never mistake one for a generation, and a
    /// constant so a test that has to tell the probe's link from a per-file link derives the
    /// distinction from here rather than restating a literal.
    static let hardLinkProbePrefix = ".hardlink-probe-"

    /// Whether the volume backing `backupRoot` supports hard links, checked once per run rather
    /// than discovered file-by-file (F532). Writes ONE throwaway file under `backupRoot` — always
    /// present by this point, since `backUp` already created it — and tries to hard-link it to a
    /// second name, through `linkItem`.
    ///
    /// `linkItem` is the same function `backUp` uses for its per-file `.skip` links, passed in
    /// rather than defaulted (F652): with the real `FileManager.linkItem` baked in here, a test that
    /// made the per-file link fail left the probe answering "links work", so the space check never
    /// budgeted for the fallback and hardcoding the answer to `true` passed every test. Required so
    /// a future caller cannot forget the seam.
    ///
    /// Defaults to `true` (the ordinary case: APFS, HFS+, most local volumes) when the probe
    /// itself cannot even run, e.g. `backupRoot` is unwritable for some unrelated reason. That
    /// failure surfaces on its own moments later, at the real copy/link inside the run, with a
    /// precise error; guessing "unsupported" here would only misreport it as a space problem.
    static func probeHardLinkSupport(
        in backupRoot: URL,
        fileManager: FileManager,
        linkItem: (URL, URL) throws -> Void
    ) -> Bool {
        let probeA = backupRoot.appendingPathComponent("\(hardLinkProbePrefix)\(UUID().uuidString)")
        let probeB = backupRoot.appendingPathComponent("\(hardLinkProbePrefix)\(UUID().uuidString)")
        defer {
            try? fileManager.removeItem(at: probeA)
            try? fileManager.removeItem(at: probeB)
        }
        guard (try? Data([0]).write(to: probeA)) != nil else { return true }
        do {
            try linkItem(probeA, probeB)
            return true
        } catch {
            return false
        }
    }
}
