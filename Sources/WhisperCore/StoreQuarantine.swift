import Foundation

public enum StoreQuarantineError: LocalizedError, Sendable, Equatable {
    case couldNotPreserve(String)

    public var errorDescription: String? {
        switch self {
        case let .couldNotPreserve(name):
            return "\(name) could not be read and could not be copied aside, so it was left untouched and nothing was written."
        }
    }
}

/// Copies bytes that exist but do not decode to a timestamped sibling, so a later write can never be
/// the only thing standing between the user and their data (F187).
public enum StoreQuarantine {
    /// Copies `url` aside as `<stem>.unreadable-<ISO8601>.<ext>` and returns the new file's name.
    /// Returns nil when `url` does not exist.
    ///
    /// Goes through `StoreFileIO` so the `quarantine` phase is individually failable (F190). It was
    /// a `FileManager` before, which could not be faulted: preserve-before-overwrite is the rule
    /// that stands between a decode failure and a wiped library, and "what happens when preserving
    /// itself fails" has to be testable at the exact call rather than by making a whole directory
    /// read-only.
    ///
    /// Copies, never moves: a move would leave `load()` seeing no file at all, which returns nil and
    /// re-opens the rebuild path this ticket closes. Idempotent per (file, byte content) so a launch
    /// loop cannot fill the folder with duplicates.
    public static func preserve(fileAt url: URL, using io: StoreFileIO = .live) throws -> String? {
        guard io.fileExists(url) else { return nil }
        guard let bytes = try? io.read(url, .quarantine) else {
            throw StoreQuarantineError.couldNotPreserve(url.lastPathComponent)
        }
        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let marker = "\(stem).unreadable-"

        let siblings = (try? io.contentsOfDirectory(directory, .quarantine)) ?? []
        for sibling in siblings where sibling.hasPrefix(marker) {
            let existing = directory.appendingPathComponent(sibling)
            if let existingBytes = try? io.read(existing, .quarantine), existingBytes == bytes {
                return sibling
            }
        }

        let stamp = ISO8601DateFormatter.quarantineStamp.string(from: Date())
        let name = ext.isEmpty ? "\(marker)\(stamp)" : "\(marker)\(stamp).\(ext)"
        do {
            try io.writeAtomically(bytes, directory.appendingPathComponent(name), .quarantine)
        } catch {
            throw StoreQuarantineError.couldNotPreserve(url.lastPathComponent)
        }
        return name
    }
}

private extension ISO8601DateFormatter {
    /// Colons are legal in HFS+/APFS names but confusing in paths, so use a filename-safe stamp.
    static let quarantineStamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
