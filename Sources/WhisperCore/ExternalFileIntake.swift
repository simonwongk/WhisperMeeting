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

    static func isImportable(_ url: URL) -> Bool {
        guard url.isFileURL, !url.pathExtension.isEmpty,
              let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie) || type.conforms(to: .audiovisualContent)
    }
}
