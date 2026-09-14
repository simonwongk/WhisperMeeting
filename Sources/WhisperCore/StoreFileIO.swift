import Foundation

/// A file's identity as the filesystem sees it (F190/F211).
///
/// `stat(2)` only — never opened, never read. An atomic replace moves the inode and an in-place
/// rewrite moves `ctime`, so comparing this before and after is how a foreign write is detected
/// without re-reading the file.
public struct StoreFileIdentity: Sendable, Equatable {
    public let device: Int32
    public let inode: UInt64
    public let size: Int64
    public let modifiedSeconds: Int, modifiedNanoseconds: Int
    public let changedSeconds: Int, changedNanoseconds: Int

    /// nil when the file is absent or cannot be stat'ed.
    public init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec
        changedNanoseconds = info.st_ctimespec.tv_nsec
    }
}

/// Every distinct filesystem effect in the write protocol, so a test can fail exactly one (F190).
///
/// The phase is passed BY THE PRODUCTION CODE and never inferred from a URL suffix: `rename` serves
/// both `install` and `rotateBackup`, `writeAtomically` serves both `stage` and `commit`, and
/// suffix-matching cannot tell those apart. Without that, the ticket's "fault-injection tests cover
/// every write phase" clause is unsatisfiable — a coarser seam can only fail "some write".
///
/// The full protocol's phases are all declared here, including those no code performs yet
/// (`stage`, `commit`, `retain`, `prune`, `preserveConflictBranch`, the history phases). Declaring
/// them up front is deliberate: `StoreWritePhase.allCases` is what the recovery matrix in design
/// §9.2 loops over, so a phase added later without a recovery row fails the suite rather than
/// going quietly untested.
public enum StoreWritePhase: String, Sendable, CaseIterable, Codable {
    case prepareDirectory
    case readPrimary, readBackup, readLedger, listHistory, readHistoryEntry
    case quarantine
    case preserveConflictBranch
    case stage
    case createHistoryDirectory, retain
    case rotateBackup
    case install
    case commit
    case prune
}

public enum StoreIOError: Error, Sendable, Equatable {
    case destinationExists(String)
    case posix(operation: String, path: String, code: Int32)
}

/// The filesystem, as a value (F190). Defaults are the real Foundation/POSIX calls; a test
/// substitutes a copy with one operation faulted.
///
/// The existing `fileManager` parameter could not do this job. It is used only for
/// `createDirectory` and `fileExists`, while every byte read and write bypasses it and F211's
/// identity check calls raw `stat()`. It is an ownership seam, not an IO seam. Subclassing
/// `FileManager` is worse: routing contents through `contents(atPath:)`/`createFile` loses
/// `Data.write(options: .atomic)`'s temp-then-rename, which F187's preserve rule, F211's inode
/// identity and this design's install step all stand on.
public struct StoreFileIO: Sendable {
    public var read: @Sendable (URL, StoreWritePhase) throws -> Data
    /// `Data.write(options: .atomic)` — temp + rename. Never `FileManager.createFile`.
    public var writeAtomically: @Sendable (Data, URL, StoreWritePhase) throws -> Void
    /// `FileManager.copyItem` — `clonefile(2)` on APFS (O(1), separate inode), byte copy elsewhere.
    /// Reports `.destinationExists` when the destination is already there; callers treat that as
    /// success for content-addressed names.
    public var copyItem: @Sendable (URL, URL, StoreWritePhase) throws -> Void
    public var rename: @Sendable (URL, URL, StoreWritePhase) throws -> Void
    public var remove: @Sendable (URL, StoreWritePhase) throws -> Void
    public var createDirectory: @Sendable (URL, StoreWritePhase) throws -> Void
    public var contentsOfDirectory: @Sendable (URL, StoreWritePhase) throws -> [String]
    /// nil when absent; true/false for directory-ness. Lets a caller detect a plain FILE squatting
    /// a directory's name without `createDirectory` throwing.
    public var isDirectory: @Sendable (URL) -> Bool?
    /// MUST go through the seam. A faulted write plus a real `stat()` desyncs the F211 memory and
    /// silently turns its decode-skip into a proof it never earned.
    public var identity: @Sendable (URL) -> StoreFileIdentity?
    public var fingerprint: @Sendable (Data) -> String
    public var fileExists: @Sendable (URL) -> Bool

    public init(
        read: @escaping @Sendable (URL, StoreWritePhase) throws -> Data,
        writeAtomically: @escaping @Sendable (Data, URL, StoreWritePhase) throws -> Void,
        copyItem: @escaping @Sendable (URL, URL, StoreWritePhase) throws -> Void,
        rename: @escaping @Sendable (URL, URL, StoreWritePhase) throws -> Void,
        remove: @escaping @Sendable (URL, StoreWritePhase) throws -> Void,
        createDirectory: @escaping @Sendable (URL, StoreWritePhase) throws -> Void,
        contentsOfDirectory: @escaping @Sendable (URL, StoreWritePhase) throws -> [String],
        isDirectory: @escaping @Sendable (URL) -> Bool?,
        identity: @escaping @Sendable (URL) -> StoreFileIdentity?,
        fingerprint: @escaping @Sendable (Data) -> String,
        fileExists: @escaping @Sendable (URL) -> Bool
    ) {
        self.read = read
        self.writeAtomically = writeAtomically
        self.copyItem = copyItem
        self.rename = rename
        self.remove = remove
        self.createDirectory = createDirectory
        self.contentsOfDirectory = contentsOfDirectory
        self.isDirectory = isDirectory
        self.identity = identity
        self.fingerprint = fingerprint
        self.fileExists = fileExists
    }

    /// The real filesystem. `FileManager.default` is used per-call rather than captured: it is
    /// documented thread-safe for these operations, and holding one instance across a `Sendable`
    /// boundary is not.
    public static let live = StoreFileIO(
        read: { url, _ in try Data(contentsOf: url) },
        writeAtomically: { data, url, _ in try data.write(to: url, options: .atomic) },
        copyItem: { source, destination, _ in
            do {
                try FileManager.default.copyItem(at: source, to: destination)
            } catch let error as NSError
                where error.domain == NSCocoaErrorDomain
                && error.code == NSFileWriteFileExistsError {
                throw StoreIOError.destinationExists(destination.lastPathComponent)
            }
        },
        rename: { source, destination, _ in
            // rename(2) rather than FileManager.moveItem: it is atomic within a filesystem and
            // replaces an existing destination, which moveItem refuses to do.
            guard Foundation.rename(source.path, destination.path) == 0 else {
                throw StoreIOError.posix(operation: "rename", path: source.path, code: errno)
            }
        },
        remove: { url, _ in try FileManager.default.removeItem(at: url) },
        createDirectory: { url, _ in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        },
        contentsOfDirectory: { url, _ in
            try FileManager.default.contentsOfDirectory(atPath: url.path)
        },
        isDirectory: { url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return nil
            }
            return isDirectory.boolValue
        },
        identity: { url in StoreFileIdentity(path: url.path) },
        fingerprint: { data in StoreFingerprint.of(data) },
        fileExists: { url in FileManager.default.fileExists(atPath: url.path) }
    )
}
