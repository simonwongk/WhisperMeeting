import Foundation
import UniformTypeIdentifiers

/// Sorts files handed to the app from outside — Finder "Open With", a drop on the Dock icon,
/// Shortcuts' "Open File", the "Transcribe with WhisperMeet" service — into what the importer can
/// read and what it cannot (F181). The same three types the in-app importer's file panel allows.
public enum ExternalFileIntake {
    public static func sort(_ urls: [URL]) -> (importable: [URL], rejected: [URL]) {
        var importable: [URL] = []
        var rejected: [URL] = []
        for url in urls {
            if isImportable(url) { importable.append(url) } else { rejected.append(url) }
        }
        return (importable, rejected)
    }

    public static func isImportable(_ url: URL) -> Bool {
        guard url.isFileURL, !url.pathExtension.isEmpty,
              let type = UTType(filenameExtension: url.pathExtension) else { return false }
        guard type.conforms(to: .audio) || type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) else {
            return false
        }
        // A *folder* named `foo.mp3` — a bundle, or just a badly named directory — otherwise reached
        // the importer, which copied the whole tree before failing to read a duration out of it
        // (F344). A path that does not exist stays importable: the copy reports that properly, and
        // the watched folder's listing has already established these are regular files.
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return false
        }
        return true
    }
}
