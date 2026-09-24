import Foundation

enum BackupRestoreError: LocalizedError, Equatable {
    /// The plan's generation is damaged, or could not be checked and the caller did not say to
    /// proceed anyway.
    case planIsNotSafeToApply
    /// The library's previous state could not be preserved, so the restore was not attempted.
    case couldNotSnapshotLibrary(String)
    /// The backup names a path a restore may not write: outside the library, outside what a backup
    /// contains, a folder the restore would have to delete, or a link rather than a file (F432).
    case unrestorablePath(String)

    var errorDescription: String? {
        switch self {
        case .planIsNotSafeToApply:
            return "This backup could not be confirmed intact, so nothing was restored and your library is unchanged."
        case let .couldNotSnapshotLibrary(detail):
            return "WhisperMeet could not set your current library aside before restoring, so nothing was changed. \(detail)"
        case let .unrestorablePath(path):
            return "This backup lists \"\(path)\", which is not a file a WhisperMeet backup contains, so it cannot be restored."
        }
    }
}

/// Applies a reviewed restore plan (F191 slice E2).
///
/// The first slice that writes over the user's working library. Copying the files is the easy part;
/// the properties that matter are what happens when it does **not** finish. A restore that fails
/// halfway leaves the library neither in the state the user had nor the one they asked for, which is
/// the worst outcome available — so the pre-restore snapshot is not a nicety, it is what makes the
/// operation attemptable at all.
///
/// Rollback is tested by making the copy fail, not by arguing that it would work.
enum BackupRestore {
    struct Outcome: Equatable, Sendable {
        let restoredFileCount: Int
        /// Where the library's previous state was moved. Kept after success as well as failure.
        let preRestoreSnapshot: URL?
    }

    /// Restores `plan`'s generation into `library`.
    ///
    /// **Refuses by default when the plan is not safe to apply**, including when the obstacle is
    /// merely missing evidence. An unchecked backup must not restore because nothing said no.
    /// `acceptingUnverifiedBackup` is the caller's explicit override, and it covers only the
    /// unverifiable case — a generation known to be DAMAGED is refused regardless, because there is
    /// no reading of "the user chose it" that makes copying corrupt bytes over good ones correct.
    ///
    /// `copy` is injected so rollback can be tested against a genuine mid-restore failure, which is
    /// otherwise not producible: the interesting case is the one where the filesystem gives up
    /// partway, and no fixture can arrange that.
    @discardableResult
    static func apply(
        _ plan: BackupRestorePlan,
        from generation: URL,
        into library: URL,
        acceptingUnverifiedBackup: Bool = false,
        copy: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
    ) throws -> Outcome {
        guard plan.isSafeToApply
            || (plan.requiresExplicitOverride && acceptingUnverifiedBackup) else {
            throw BackupRestoreError.planIsNotSafeToApply
        }
        // Again, although `make` already ran it (F432). The plan is a value that any caller can
        // construct, and this is the step that writes, so it does not take the planner's word.
        try plan.checkPaths(from: generation, into: library)

        let fileManager = FileManager.default
        let paths = plan.wouldOverwrite + plan.wouldAdd

        // The library's previous state, set aside before a single byte is written.
        //
        // A COPY rather than a move: moving would leave the library in a half-dismantled state for
        // the duration, so a crash during the snapshot itself — before the restore has even
        // started — would be unrecoverable. Copying costs disk and buys the property that at no
        // instant is the user's library absent.
        //
        // Kept after success too. "It worked" is the app's opinion; the user may still decide the
        // older snapshot was the wrong one, and deleting their previous state the moment the copy
        // finished would make the operation irreversible at exactly the point it became reversible.
        //
        // Inside the library and DOT-PREFIXED. Inside, because it then sits on the same volume — so the copy cannot fail for space the
        // library itself would not have — and because the user finds it in the place they already
        // know. Writing it into the parent (Application Support) risks a different volume and a
        // permission surprise at the worst moment.
        //
        // Dot-prefixed because a directory inside the library that is not part of the library's
        // schema is a hazard: `orphanedRecordings()` enumerates with `.skipsHiddenFiles`, so a
        // hidden name is invisible to it, and `BackupCoordinator` only walks `backedUpEntries`, so
        // the snapshot is never copied into a later generation. My first version was
        // `pre-restore-<epoch>` and a test caught it as an unexpected directory — which is exactly
        // how a later scan would have found it too, except in production.
        let snapshot = library
            .appendingPathComponent(".pre-restore-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        var preserved: [(original: URL, saved: URL)] = []
        do {
            try fileManager.createDirectory(at: snapshot, withIntermediateDirectories: true)
            // The files it will set aside are preserved exactly like the ones it will overwrite,
            // so rollback and a later undo treat them the same way (F463).
            for path in plan.wouldOverwrite + plan.wouldSetAside {
                let original = library.appendingPathComponent(path)
                let saved = snapshot.appendingPathComponent(path)
                try fileManager.createDirectory(
                    at: saved.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: original, to: saved)
                preserved.append((original, saved))
            }
        } catch {
            try? fileManager.removeItem(at: snapshot)
            throw BackupRestoreError.couldNotSnapshotLibrary(error.localizedDescription)
        }

        // Track what actually landed, so rollback undoes exactly that and nothing else. A rollback
        // that assumed the whole plan had been attempted would delete files it never created.
        var written: [URL] = []
        do {
            // First, before any index is replaced (F463). A restored index beside the live ledger
            // opens read-only; either index without a ledger is an unrecorded generation, which
            // the store adopts. So when the backup has no ledger of its own, a restore that dies
            // after this line — where rollback cannot run — has not left an index beside a ledger
            // that contradicts it. They are already in the snapshot.
            for path in plan.wouldSetAside {
                try fileManager.removeItem(at: library.appendingPathComponent(path))
            }
            for path in paths {
                let source = generation.appendingPathComponent(path)
                let target = library.appendingPathComponent(path)
                try fileManager.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                }
                try copy(source, target)
                written.append(target)
            }
        } catch {
            rollBack(written: written, preserved: preserved, plan: plan, library: library)
            throw error
        }

        return Outcome(restoredFileCount: paths.count, preRestoreSnapshot: snapshot)
    }

    /// Puts the library back exactly as it was found.
    ///
    /// Best-effort by necessity and deliberately silent about its own failures: it runs while
    /// another error is already propagating, and replacing that error with a rollback error would
    /// hide the reason the restore failed. What the caller needs to know is that the restore did
    /// not succeed; the snapshot directory survives either way, so the user's previous state is
    /// still on disk even if this could not put it back automatically.
    private static func rollBack(
        written: [URL],
        preserved: [(original: URL, saved: URL)],
        plan: BackupRestorePlan,
        library: URL
    ) {
        let fileManager = FileManager.default
        // Files the restore ADDED never existed before, so removing them is the whole undo.
        let added = Set(plan.wouldAdd.map { library.appendingPathComponent($0).standardizedFileURL.path })
        for url in written where added.contains(url.standardizedFileURL.path) {
            try? fileManager.removeItem(at: url)
        }
        // Files it OVERWROTE or SET ASIDE come back from the snapshot.
        for (original, saved) in preserved {
            try? fileManager.removeItem(at: original)
            try? fileManager.createDirectory(
                at: original.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? fileManager.copyItem(at: saved, to: original)
        }
    }
}
