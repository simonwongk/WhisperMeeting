import Foundation
import UniformTypeIdentifiers

/// Sorts files handed to the app from outside — Finder "Open With", a drop on the Dock icon,
/// Shortcuts' "Open File", the "Transcribe with WhisperMeet" service — into what the importer can
/// read and what it cannot (F181). The same three types the in-app importer's file panel allows.
public enum ExternalFileIntake {
    /// Sorts URLs handed over from outside, where the sender chose them and nothing has looked at
    /// the filesystem yet — so this is also where a *folder* named `foo.mp3` is caught (F344).
    public static func sort(_ urls: [URL]) -> (importable: [URL], rejected: [URL]) {
        var importable: [URL] = []
        var rejected: [URL] = []
        for url in urls {
            if isImportable(url), !isDirectory(url) { importable.append(url) } else { rejected.append(url) }
        }
        return (importable, rejected)
    }

    /// Whether the *name* says the importer can read it. Deliberately pure — no filesystem — because
    /// `WatchedFolderInbox` asks this of every candidate on every three-second look, over a listing
    /// that has already established these are regular files (F324, F344).
    public static func isImportable(_ url: URL) -> Bool {
        guard url.isFileURL, !url.pathExtension.isEmpty,
              let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie) || type.conforms(to: .audiovisualContent)
    }

    /// A bundle, or just a badly named directory. It otherwise reached the importer, which copied
    /// the whole tree before failing to read a duration out of it (F344). A path that does not exist
    /// is not a directory: the copy reports its own failure properly.
    public static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
