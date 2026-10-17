import Foundation
import WhisperCore

/// Meetings whose recording is a symbolic link to a file elsewhere (F704).
///
/// Before 3c06b0d (F494), importing a link wrote `Recordings/<id>/recording.<ext>` as a link to the
/// user's file, because `copyItem` copies a link as a link. Such a meeting plays only while the original
/// stays put, and `BackupCoordinator` skips it, since it copies regular files only. Verify Library
/// reports it (`IntegrityFinding.recordingIsSymbolicLink`), and the meeting's page offers to copy the
/// original in while it still exists.
extension AppModel {
    /// The file the meeting's recording links to, when the recording is a symbolic link whose original
    /// is still a regular file on disk; nil otherwise — not a link, or a link whose original is gone,
    /// for which there is nothing left to copy.
    func linkedRecordingOriginal(id: UUID) -> URL? {
        guard let meeting = store.meeting(id: id), !meeting.recordingPath.isEmpty else { return nil }
        let recording = store.recordingURL(for: meeting)
        guard MeetingIntegrityChecker.isSymbolicLink(recording) else { return nil }
        let original = recording.resolvingSymlinksInPath()
        guard original.standardizedFileURL != recording.standardizedFileURL,
              ((try? FileManager.default.attributesOfItem(atPath: original.path))?[.type] as? FileAttributeType) == .typeRegular
        else { return nil }
        return original
    }

    /// Replaces the meeting's linked recording with a copy of the file it links to (F704).
    ///
    /// Never destroys anything: the original is only read, the copy is made beside the link under a
    /// name nothing else uses, checked to have the original's size, and only then renamed over the link
    /// — one atomic step that replaces the link itself, not the file it points to. Any failure removes
    /// the partial copy and leaves the link as it was. Refused on a read-only library or during a
    /// restore (nothing is written then), and while a delete of this meeting is under way (F870).
    @discardableResult
    func copyLinkedRecordingIntoLibrary(id: UUID) async -> Bool {
        if store.isDegraded {
            alertMessage = ReadOnlyLibraryNotice.mutationRefused
            return false
        }
        if store.isRestoringLibrary {
            alertMessage = MeetingStore.changeRefusedDuringRestore
            return false
        }
        guard let meeting = store.meeting(id: id), let original = linkedRecordingOriginal(id: id) else {
            alertMessage = "That recording is no longer a link to a file WhisperMeet can copy, so nothing was changed."
            return false
        }
        let writers = store.folderWriters
        guard writers.begin(id) else {
            alertMessage = "That meeting is being deleted, so its recording was not copied."
            return false
        }
        defer { writers.end(id) }
        let link = store.recordingURL(for: meeting)
        let title = meeting.title
        let outcome: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
            Result { try Self.replaceLink(link, withCopyOf: original) }
        }.value
        switch outcome {
        case .success:
            alertMessage = "“\(title)” now has its own copy of its recording, so it no longer depends on the original file and is included in backups. The original was not changed."
            return true
        case let .failure(error):
            alertMessage = "The recording of “\(title)” could not be copied into the library, so nothing was changed. \(error.localizedDescription)"
            return false
        }
    }

    /// The copy-then-rename behind `copyLinkedRecordingIntoLibrary`. `nonisolated` file work.
    nonisolated static func replaceLink(_ link: URL, withCopyOf original: URL) throws {
        let fileManager = FileManager.default
        let temporary = link.deletingLastPathComponent()
            .appendingPathComponent(".\(link.lastPathComponent).copying-\(UUID().uuidString)")
        do {
            try fileManager.copyItem(at: original, to: temporary)
            let expected = (try fileManager.attributesOfItem(atPath: original.path)[.size] as? NSNumber)?.int64Value
            let copied = (try fileManager.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value
            guard let expected, expected == copied else { throw CocoaError(.fileWriteUnknown) }
            // Only a link may be replaced: anything else at that name since the check is left alone.
            guard MeetingIntegrityChecker.isSymbolicLink(link) else { throw CocoaError(.fileWriteFileExists) }
            guard rename(temporary.path, link.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }
}
