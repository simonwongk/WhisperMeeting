import Foundation
import WhisperCore

/// Meetings whose recording is a symbolic link to a file elsewhere (F704).
///
/// Before 3c06b0d (F494), importing a link wrote `Recordings/<id>/recording.<ext>` as a link to the
/// user's file, because `copyItem` copies a link as a link. Such a meeting plays only while the original
/// stays put, and `BackupCoordinator` skips it, since it copies regular files only. Verify Library
/// reports it (`IntegrityFinding.recordingIsSymbolicLink`), and the meeting's page offers to copy the
/// original in while it still exists.
///
/// Round 2: nothing here touches the filesystem on the main actor. The original can be on a network
/// share that has stopped answering, where a `stat` blocks for the share's timeout, so the page reads
/// `linkedRecordingOffers`, which `refreshLinkedRecordingOffer(id:)` fills from a detached task.
extension AppModel {
    /// The regular file `link` points at, when `link` is itself a symbolic link and its original is
    /// still a regular file; nil otherwise — not a link, or a link whose original is gone, for which
    /// there is nothing left to copy. Blocking file work: call it off the main actor.
    nonisolated static func linkedOriginal(of link: URL) -> URL? {
        guard MeetingIntegrityChecker.isSymbolicLink(link) else { return nil }
        let original = link.resolvingSymlinksInPath()
        guard original.standardizedFileURL != link.standardizedFileURL,
              ((try? FileManager.default.attributesOfItem(atPath: original.path))?[.type] as? FileAttributeType) == .typeRegular
        else { return nil }
        return original
    }

    /// Checks, off the main actor, whether the meeting's recording is a link to an original that is
    /// still there, and records the answer in `linkedRecordingOffers` for the meeting page.
    func refreshLinkedRecordingOffer(id: UUID) async {
        guard let meeting = store.meeting(id: id), !meeting.recordingPath.isEmpty else {
            linkedRecordingOffers[id] = nil
            return
        }
        let recording = store.recordingURL(for: meeting)
        let probe = linkedRecordingProbe
        let original = await Task.detached(priority: .utility) { probe(recording) }.value
        if linkedRecordingOffers[id] != original { linkedRecordingOffers[id] = original }
    }

    /// Replaces the meeting's linked recording with a copy of the file it links to (F704).
    ///
    /// Never destroys anything: the original is only read, the copy is made beside the link under a
    /// name nothing else uses, checked to have the original's size, and only then renamed over the link
    /// — one atomic step that replaces the link itself, not the file it points to. Any failure removes
    /// the partial copy and leaves the link as it was. Refused on a read-only library or during a
    /// restore (nothing is written then), and while a delete of this meeting is under way (F870). A
    /// second request while one is running is turned away without a message (round 2), so a double
    /// click cannot put "could not be copied" over the first one's success.
    @discardableResult
    func copyLinkedRecordingIntoLibrary(id: UUID) async -> Bool {
        guard !copyingLinkedRecordingIDs.contains(id) else { return false }
        if store.isDegraded {
            alertMessage = ReadOnlyLibraryNotice.mutationRefused
            return false
        }
        if store.isRestoringLibrary {
            alertMessage = MeetingStore.changeRefusedDuringRestore
            return false
        }
        guard let meeting = store.meeting(id: id), !meeting.recordingPath.isEmpty else {
            alertMessage = Self.linkedRecordingNotCopyable
            return false
        }
        let writers = store.folderWriters
        guard writers.begin(id) else {
            alertMessage = "That meeting is being deleted, so its recording was not copied."
            return false
        }
        copyingLinkedRecordingIDs.insert(id)
        defer {
            copyingLinkedRecordingIDs.remove(id)
            writers.end(id)
        }
        let link = store.recordingURL(for: meeting)
        let title = meeting.title
        let probe = linkedRecordingProbe
        let outcome: Result<Bool, Error> = await Task.detached(priority: .userInitiated) {
            Result {
                guard let original = probe(link) else { return false }
                try Self.replaceLink(link, withCopyOf: original)
                return true
            }
        }.value
        switch outcome {
        case .success(true):
            linkedRecordingOffers[id] = nil
            alertMessage = "“\(title)” now has its own copy of its recording, so it no longer depends on the original file and is included in backups. The original was not changed."
            return true
        case .success(false):
            linkedRecordingOffers[id] = nil
            alertMessage = Self.linkedRecordingNotCopyable
            return false
        case let .failure(error):
            alertMessage = "The recording of “\(title)” could not be copied into the library, so nothing was changed. \(ErrorPresentation.readable(error))"
            return false
        }
    }

    static let linkedRecordingNotCopyable = "That recording is no longer a link to a file WhisperMeet can copy, so nothing was changed."

    /// The copy-then-rename behind `copyLinkedRecordingIntoLibrary`. `nonisolated` file work. `copy`
    /// is the copier, injectable only so a test can hand the size check a copy that came out short.
    nonisolated static func replaceLink(
        _ link: URL,
        withCopyOf original: URL,
        copy: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
    ) throws {
        let fileManager = FileManager.default
        let temporary = link.deletingLastPathComponent()
            .appendingPathComponent(".\(link.lastPathComponent).copying-\(UUID().uuidString)")
        do {
            try copy(original, temporary)
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
