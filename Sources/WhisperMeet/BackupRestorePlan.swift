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
    static func make(from generation: URL, into library: URL, deep: Bool) throws -> BackupRestorePlan {
        let verification = try BackupManifest.verify(in: generation, deep: deep)
        let manifest = BackupManifest.read(in: generation)

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
            backupFiles = relativeFileSizes(in: generation, skipping: [
                BackupCoordinator.completionMarker, BackupManifest.fileName,
            ])
        }
        let libraryFiles = relativeFileSizes(in: library, skipping: [])

        let backupPaths = Set(backupFiles.keys)
        let libraryPaths = Set(libraryFiles.keys)

        let overwrite = backupPaths.intersection(libraryPaths).sorted()
        let add = backupPaths.subtracting(libraryPaths).sorted()
        // Restricted to the entries a backup covers at all. Without this, every install log and
        // downloaded runtime in the library would be reported as "not in the backup" — true, and
        // noise that would bury the two or three lines the user needs to read.
        let missing = libraryPaths
            .subtracting(backupPaths)
            .filter { path in
                BackupCoordinator.backedUpEntries.contains {
                    path == $0 || path.hasPrefix("\($0)/")
                }
            }
            .sorted()

        return BackupRestorePlan(
            generation: manifest?.generation ?? generation.lastPathComponent,
            createdAtEpoch: manifest?.createdAtEpoch ?? 0,
            wouldOverwrite: overwrite,
            wouldAdd: add,
            notInBackup: missing,
            bytesToWrite: backupPaths.reduce(Int64(0)) { $0 + (backupFiles[$1] ?? 0) },
            verification: verification
        )
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
