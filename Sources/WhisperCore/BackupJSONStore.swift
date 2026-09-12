import Foundation

public enum BackupJSONStoreError: LocalizedError, Sendable, Equatable {
    case noReadableCopy(primary: String, backup: String, quarantined: [String])

    public var errorDescription: String? {
        switch self {
        case let .noReadableCopy(primary, backup, quarantined):
            // Claim only the preservation that actually happened (F187). The prior wording promised
            // preservation unconditionally while nothing preserved anything.
            guard !quarantined.isEmpty else {
                return "Neither \(primary) nor its backup \(backup) could be read, and neither could be copied aside. Nothing was changed on disk."
            }
            return "Neither \(primary) nor its backup \(backup) could be read. The exact bytes were copied aside as \(quarantined.joined(separator: " and ")) and nothing was overwritten."
        }
    }
}

/// A value rebuilt from a partly-unreadable file, plus the records that had to be left behind.
public struct SalvagedValue<Value>: Sendable where Value: Sendable {
    public let value: Value
    public let parkedIdentifiers: [String]

    public init(value: Value, parkedIdentifiers: [String]) {
        self.value = value
        self.parkedIdentifiers = parkedIdentifiers
    }
}

/// Which files this process has already proved decodable, identified by their exact bytes on disk
/// (F211).
///
/// It remembers an *identity*, never the contents. An earlier draft cached the bytes too, which was
/// worse on both axes that matter here: it held two whole serialized generations per store forever
/// (~4.2 MB today, ~24 MB at a hundred meetings — the opposite of the memory behaviour this work is
/// for), and it let a foreign write that landed between `write` and `stat` poison the entry so that
/// *our* stale bytes would be served for the foreign file's identity. Re-reading is a few
/// milliseconds; the `Codable` decode of a deeply nested index is tens. Skipping only the decode
/// keeps nearly all the win and leaves the bytes always coming from disk.
///
/// A reference type on purpose: `BackupJSONStore` is a struct, and every copy of it addresses the
/// same files, so they must share one memory.
private final class DecodableFileMemory: @unchecked Sendable {
    /// Enough of `stat` to tell "still exactly the bytes I proved" from "somebody wrote here".
    /// `ctime` is included so an *in-place* overwrite is caught too: an atomic replace changes the
    /// inode, but `cp` onto the path or an editor saving in place does not, and on a
    /// coarse-mtime volume (SMB, exFAT) a same-size rewrite could otherwise land on the same
    /// second and read as unchanged.
    struct Identity: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init?(path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
            size = Int64(info.st_size)
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanoseconds = info.st_ctimespec.tv_nsec
        }
    }

    private let lock = NSLock()
    private var proven: [String: Identity] = [:]

    /// Records that the file at `path` currently holds `byteCount` decodable bytes.
    ///
    /// Takes the identity twice and keeps it only if both agree, and only if the size matches what
    /// was written. A foreign writer that slipped in between the write and the check would move one
    /// of them, and the entry is dropped rather than attributed to bytes we never verified.
    func remember(path: String, byteCount: Int) {
        guard let first = Identity(path: path),
              let second = Identity(path: path),
              first == second,
              first.size == Int64(byteCount)
        else {
            forget(path)
            return
        }
        lock.lock()
        proven[path] = first
        lock.unlock()
    }

    /// Whether the file is still, byte for byte, one this process already decoded successfully.
    func isProvenDecodable(path: String) -> Bool {
        guard let current = Identity(path: path) else { return false }
        lock.lock()
        defer { lock.unlock() }
        return proven[path] == current
    }

    func forget(_ path: String) {
        lock.lock()
        proven.removeValue(forKey: path)
        lock.unlock()
    }
}

public struct BackupJSONStore<Value: Codable & Sendable> {
    public struct LoadResult {
        public let value: Value
        public let health: PersistedStoreHealth
    }

    private let primaryURL: URL
    private let backupURL: URL
    private let fileManager: FileManager
    /// Optional element-wise recovery so one bad record costs one record, not the whole library (F187).
    private let salvage: (@Sendable (Data) -> SalvagedValue<Value>?)?
    private let decodableMemory = DecodableFileMemory()

    public init(
        primaryURL: URL,
        backupURL: URL,
        fileManager: FileManager = .default,
        salvage: (@Sendable (Data) -> SalvagedValue<Value>?)? = nil
    ) {
        self.primaryURL = primaryURL
        self.backupURL = backupURL
        self.fileManager = fileManager
        self.salvage = salvage
    }

    public func load() throws -> LoadResult? {
        let primaryExists = fileManager.fileExists(atPath: primaryURL.path)
        let backupExists = fileManager.fileExists(atPath: backupURL.path)

        if primaryExists,
           let data = try? Data(contentsOf: primaryURL),
           let value = try? decoder.decode(Value.self, from: data) {
            return LoadResult(value: value, health: .complete)
        }
        if backupExists,
           let data = try? Data(contentsOf: backupURL),
           let value = try? decoder.decode(Value.self, from: data) {
            return LoadResult(value: value, health: .recoveredFromBackup)
        }
        guard primaryExists || backupExists else { return nil }

        // Preserve first, then try to rescue individual records from the preserved bytes.
        var quarantined: [String] = []
        if let name = try StoreQuarantine.preserve(fileAt: primaryURL, using: fileManager) {
            quarantined.append(name)
        }
        if let name = try StoreQuarantine.preserve(fileAt: backupURL, using: fileManager) {
            quarantined.append(name)
        }

        if let salvage {
            for url in [primaryURL, backupURL] {
                guard let data = try? Data(contentsOf: url), let rescued = salvage(data) else { continue }
                return LoadResult(
                    value: rescued.value,
                    health: .partiallySalvaged(parkedIdentifiers: rescued.parkedIdentifiers)
                )
            }
        }

        throw BackupJSONStoreError.noReadableCopy(
            primary: primaryURL.lastPathComponent,
            backup: backupURL.lastPathComponent,
            quarantined: quarantined
        )
    }

    public func save(_ value: Value) throws {
        try fileManager.createDirectory(
            at: primaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let newData = try encoder.encode(value)
        let existingPrimary = knownOrReadableData(at: primaryURL)
        let existingBackup = knownOrReadableData(at: backupURL)

        // Preserve anything that exists but does not decode BEFORE either write can replace it (F187).
        // "Undecodable" is not "worthless": conflating them is what destroyed the library on 2026-08-14.
        // If the bytes cannot be preserved, refuse to write at all — surfacing an error beats losing data.
        if existingPrimary == nil {
            _ = try StoreQuarantine.preserve(fileAt: primaryURL, using: fileManager)
        }
        if existingBackup == nil {
            _ = try StoreQuarantine.preserve(fileAt: backupURL, using: fileManager)
        }

        let backupData = existingPrimary ?? existingBackup ?? newData
        // Forget before writing: if a write fails partway, no stale identity may survive to make a
        // later save trust a file it never actually proved.
        decodableMemory.forget(backupURL.path)
        decodableMemory.forget(primaryURL.path)
        try backupData.write(to: backupURL, options: .atomic)
        decodableMemory.remember(path: backupURL.path, byteCount: backupData.count)
        try newData.write(to: primaryURL, options: .atomic)
        decodableMemory.remember(path: primaryURL.path, byteCount: newData.count)
    }

    /// `readableData`, minus the *decode* when this file is still exactly one this process already
    /// decoded successfully (F211). The bytes always come from disk; only the proof is reused.
    ///
    /// The identity check is the whole safety argument: an atomic replace changes the inode and an
    /// in-place rewrite changes ctime, so any foreign write misses the memory and takes the full
    /// decode — which is what keeps F187's preserve-before-overwrite rule exactly as strict as it
    /// was. Worth it because the skipped work is a `Codable` decode of the entire index on the main
    /// actor, and it grows with the library: 61 ms per save at 2.6 MB, 352 ms at a hundred meetings.
    private func knownOrReadableData(at url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if decodableMemory.isProvenDecodable(path: url.path) { return data }
        guard (try? decoder.decode(Value.self, from: data)) != nil else { return nil }
        decodableMemory.remember(path: url.path, byteCount: data.count)
        return data
    }

    private func readableData(at url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url),
              (try? decoder.decode(Value.self, from: data)) != nil else {
            return nil
        }
        return data
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
