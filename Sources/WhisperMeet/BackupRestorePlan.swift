import Foundation

/// What restoring a backup generation over the live library would do (F191 slice E1).
///
/// A restore is the most dangerous operation this app performs: it copies a snapshot over the
/// user's working library. Slices A-D existed to make the snapshot trustworthy enough for that to
/// be safe at all — a complete inventory, a hash that does not exhaust memory, publication that
/// cannot be destroyed by a concurrent run, and a manifest that can be checked. This slice is the
/// part that makes the danger **inspectable**, and it ships before anything that writes.
///
/// It is pure. A dry run that modified anything would be worse than no dry run, because the user
/// ran it precisely to avoid committing, and a test asserts that both trees are byte-for-byte
/// unchanged afterwards.
///
/// **The third set is the point.** A plan listing what would be overwritten and what would be added
/// is two thirds honest. The set that matters is what the live library has and the backup does
/// **not** — the user's newer meetings, the ones a restore would silently drop. The app knows it,
/// so it has to say it. That is F281's rule in the place where omitting it costs most.
struct BackupRestorePlan: Equatable, Sendable {
    /// The generation this plan describes.
    let generation: String
    let createdAtEpoch: Int

    /// Files present in both: the restore replaces the library's copy.
    let wouldOverwrite: [String]
    /// Files the backup has and the library does not: the restore brings them back.
    let wouldAdd: [String]
    /// **Files the library has and the backup does not.** A restore does not delete these — it only
    /// copies — so they survive. But the meetings they belong to are absent from the restored
    /// index, so they become unreferenced on disk, which is the F255 harm arriving by a different
    /// road. Naming them is the difference between a restore the user chose and one they regret.
    let notInBackup: [String]
    /// **Live index files the restore moves into the pre-restore snapshot** (F463): the previous
    /// generation and ledger of an index the backup replaces but carries no such file for — every
    /// backup made before F191 slice A. Left in place, the live ledger would describe a generation
    /// that is no longer there, and the next load reads that as a rival writer and opens the library
    /// read-only. Moved rather than deleted, because undoing the restore needs them back. Not in
    /// `notInBackup`: they are not left on disk, and they are not meetings.
    let wouldSetAside: [String]

    let bytesToWrite: Int64
    let verification: BackupManifest.VerificationResult

    /// Whether this generation can be restored without the user overriding a warning.
    ///
    /// False for a damaged generation and false for an unverifiable one, and the two are not the
    /// same refusal — see `requiresExplicitOverride`.
    var isSafeToApply: Bool { verification.isIntact }

    /// True when the obstacle is missing evidence rather than known damage.
    ///
    /// A generation written before slice D has no manifest. Refusing it outright would turn an
    /// improvement into data loss for the user who most needs the backup, so it stays restorable —
    /// but only deliberately. "This cannot be checked" and "this is damaged" call for different
    /// decisions and stay distinguishable all the way to the user.
    var requiresExplicitOverride: Bool { verification.isUnverifiable }

    /// Builds a plan. Reads both trees, writes nothing.
    ///
    /// `deep` is passed through to the manifest check: presence-and-size in milliseconds, or a full
    /// re-hash that takes minutes on a library of recordings. A caller showing a sheet uses the
    /// cheap one and offers the deep one; the result records which was done, because presenting an
    /// unchecked generation as verified is the failure this whole slice exists to prevent.
    /// The chosen folder is not a backup generation at all (F288).
    ///
    /// Distinct from "unverifiable": that is a generation with no manifest, which is an *older*
    /// backup and stays restorable by explicit override. This is a folder with no manifest **and**
    /// no index at its root — the `WhisperMeet Backups` container, a holiday-photos folder — and
    /// planning it produced, on screen, an offer to copy whatever it held into the library while
    /// listing every real file as "not in this backup".
    struct NotABackupGeneration: LocalizedError, Equatable {
        let path: String
        var errorDescription: String? {
            "\"\(path)\" is not a backup generation. Choose one dated folder inside \"\(BackupCoordinator.managedSubfolder)\" — the one holding meetings.json."
        }
    }

    static func make(from generation: URL, into library: URL, deep: Bool) throws -> BackupRestorePlan {
        let manifest = BackupManifest.read(in: generation)
        // Asked before verification, because verification's answer for a folder with no manifest
        // is "unverifiable", which reads as an older backup — and this is not one.
        if manifest == nil, !FileManager.default.fileExists(
            atPath: generation.appendingPathComponent("meetings.json").path
        ) {
            throw NotABackupGeneration(path: generation.lastPathComponent)
        }
        // Before verification, which would otherwise hash whatever a hostile list points at (F432).
        // A manifest is the list this app writes, so a path it would never write means the list
        // was not written by these rules — and the manifest cannot say who did, because it is an
        // integrity check and not a signature. Refused whole rather than filtered: restoring the
        // rest of a list known to be tampered with is not a restore the user asked for.
        if let manifest,
           let path = manifest.files.map(\.relativePath).sorted().first(where: { !isRestorablePath($0) }) {
            throw BackupRestoreError.unrestorablePath(path)
        }
        let verification = try BackupManifest.verify(in: generation, deep: deep)

        // The backup's file set. From the manifest when there is one — it is the authoritative
        // list, and using it means a file the manifest omits is not silently restored — and from
        // the directory otherwise, which is the only option for a pre-slice-D generation.
        let backupFiles: [String: Int64]
        if let manifest {
            backupFiles = Dictionary(
                manifest.files.map { ($0.relativePath, $0.size) },
                uniquingKeysWith: { first, _ in first }
            )
        } else {
            // A folder holds whatever was put in it: backups made before F137 copied the whole
            // Application Support directory, runtime included, and Finder leaves `.DS_Store` in
            // any folder someone opened. Those are dropped rather than refused, because this is
            // still the user's backup — they are simply not part of a library (F432).
            backupFiles = relativeFileSizes(in: generation, skipping: [
                BackupCoordinator.completionMarker, BackupManifest.fileName,
            ]).filter { isRestorablePath($0.key) }
        }
        let libraryFiles = relativeFileSizes(in: library, skipping: [])

        let backupPaths = Set(backupFiles.keys)
        let libraryPaths = Set(libraryFiles.keys)

        let overwrite = backupPaths.intersection(libraryPaths).sorted()
        let add = backupPaths.subtracting(libraryPaths).sorted()
        // Only for an index whose primary the backup replaces. When the backup has no copy of an
        // index at all, the live one stays, and its lineage belongs with it.
        let setAside = BackupCoordinator.indexStems.flatMap { stem -> [String] in
            let files = BackupCoordinator.indexFiles(of: stem)
            guard backupPaths.contains(files.primary) else { return [] }
            return files.lineage.filter { libraryPaths.contains($0) && !backupPaths.contains($0) }
        }.sorted()
        // Restricted to the entries a backup covers at all. Without this, every install log and
        // downloaded runtime in the library would be reported as "not in the backup" — true, and
        // noise that would bury the two or three lines the user needs to read.
        let missing = libraryPaths
            .subtracting(backupPaths)
            .subtracting(setAside)
            .filter(isCoveredByBackup)
            .sorted()

        let plan = BackupRestorePlan(
            generation: manifest?.generation ?? generation.lastPathComponent,
            createdAtEpoch: manifest?.createdAtEpoch ?? 0,
            wouldOverwrite: overwrite,
            wouldAdd: add,
            notInBackup: missing,
            wouldSetAside: setAside,
            bytesToWrite: backupPaths.reduce(Int64(0)) { $0 + (backupFiles[$1] ?? 0) },
            verification: verification
        )
        // Here as well as in `apply`, so a backup that cannot be restored is refused before the
        // user is asked to confirm it rather than after.
        try plan.checkPaths(from: generation, into: library)
        return plan
    }

    /// Whether `relativePath` names a file a backup of this library can contain (F432).
    ///
    /// Relative, with no empty, `.` or `..` component, and under one of
    /// `BackupCoordinator.backedUpEntries` — the list every backup is written from, so this and the
    /// backup cannot disagree about what a library holds. `../../LaunchAgents/x.plist` fails the
    /// first half and `Runtime/venv/bin/whisper` the second.
    static func isRestorablePath(_ relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return false
        }
        return isCoveredByBackup(relativePath)
    }

    /// Whether `relativePath` is one of the entries a backup covers, or inside one.
    static func isCoveredByBackup(_ relativePath: String) -> Bool {
        BackupCoordinator.backedUpEntries.contains {
            relativePath == $0 || relativePath.hasPrefix("\($0)/")
        }
    }

    /// The one path check a restore passes: when the plan is made, and again before it is applied
    /// (F432). Throws `BackupRestoreError.unrestorablePath` for the first path that fails.
    ///
    /// The name check is not enough on its own, because `Recordings` passes it: it is a covered
    /// entry. Named exactly, it is the folder holding every recording, and `apply` removed whatever
    /// stood at a target before copying over it. So every target must also be a file or absent —
    /// never a folder — and containment is checked on the standardized URL as well as on the name.
    ///
    /// Every source must be a regular file that resolves inside the generation. A backup is written
    /// from regular files and never holds a link, so one that does was placed there, and a link
    /// copied into the library points every later write to that name wherever its author chose. A
    /// source that is ABSENT passes: verification already reports it as missing, and the copy
    /// fails on it and rolls back, so refusing it here would only replace a precise message with a
    /// vaguer one.
    func checkPaths(from generation: URL, into library: URL) throws {
        let generationRoot = generation.resolvingSymlinksInPath()
        // `wouldSetAside` is removed from the library, so its targets pass the same test; it has no
        // source, because nothing is copied in its place.
        for path in wouldOverwrite + wouldAdd + wouldSetAside {
            let target = library.appendingPathComponent(path)
            guard Self.isRestorablePath(path),
                  MeetingStore.isWithinLibrary(target, root: library),
                  Self.itemType(at: target) != .typeDirectory else {
                throw BackupRestoreError.unrestorablePath(path)
            }
        }
        for path in wouldOverwrite + wouldAdd {
            let source = generation.appendingPathComponent(path)
            if let type = Self.itemType(at: source) {
                guard type == .typeRegular,
                      MeetingStore.isWithinLibrary(source.resolvingSymlinksInPath(), root: generationRoot) else {
                    throw BackupRestoreError.unrestorablePath(path)
                }
            }
        }
    }

    /// The type of the item itself — a link is reported as a link, not as what it points at.
    private static func itemType(at url: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }

    /// Every file under `root`, by path relative to it, with its size. Missing root reads as empty
    /// rather than throwing: restoring into a library whose index is gone is the F252 case, and the
    /// most important one this has to describe.
    private static func relativeFileSizes(in root: URL, skipping: Set<String>) -> [String: Int64] {
        let base = root.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return [:] }

        var out: [String: Int64] = [:]
        while let item = walker.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            let path = item.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            let relative = String(path.dropFirst(base.count + 1))
            guard !skipping.contains(relative) else { continue }
            out[relative] = Int64(values?.fileSize ?? 0)
        }
        return out
    }
}
