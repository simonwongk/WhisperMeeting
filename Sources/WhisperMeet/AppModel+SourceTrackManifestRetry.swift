import Foundation
import WhisperCore

/// Writing back a missing `source-tracks.json` for an indexed capture (F753).
///
/// `AudioCaptureEngine.stop()` writes the manifest best-effort once the mix has succeeded (F502), and
/// `stopRecording` then indexes the meeting, so a failed write was never retried: recovery's backfill
/// reaches only unindexed folders, and `SourceRebuild` never offers one over a complete `meeting.wav`.
/// Verify Library reported the tracks as unchecked (F638) and nothing could fix it, because the
/// per-track offsets existed only in memory at `stop()`. Since F753 `stopRecording` keeps them in the
/// session sidecar, and this pass — folded into `performStartupRecovery` — writes the manifest from
/// them. A meeting whose session has no such record (a build before F753) gets nothing, not zeros.
extension AppModel {
    /// Runs `retrySourceTrackManifest` for every indexed meeting whose recording is a capture's
    /// `meeting.wav` with no manifest beside it, and returns how many manifests were written. Writes
    /// nothing on a read-only library or during a restore, and skips a meeting being deleted (F870).
    @discardableResult
    func retryMissingSourceTrackManifests() async -> Int {
        guard !store.isDegraded, !store.isRestoringLibrary else { return 0 }
        let candidates: [(UUID, URL)] = store.meetings.compactMap { meeting in
            guard meeting.id != activeMeetingID, !meeting.recordingPath.isEmpty else { return nil }
            let recording = store.recordingURL(for: meeting)
            guard recording.lastPathComponent == "meeting.wav" else { return nil }
            let directory = recording.deletingLastPathComponent()
            let fileManager = FileManager.default
            guard !fileManager.fileExists(atPath: directory.appendingPathComponent("source-tracks.json").path),
                  !fileManager.fileExists(atPath: directory.appendingPathComponent("source-tracks.recovered.json").path)
            else { return nil }
            return (meeting.id, directory)
        }
        guard !candidates.isEmpty else { return 0 }
        let retry = retrySourceTrackManifest
        let writers = store.folderWriters
        return await Task.detached(priority: .utility) {
            candidates.reduce(into: 0) { written, candidate in
                guard writers.begin(candidate.0) else { return }
                defer { writers.end(candidate.0) }
                if retry(candidate.1) { written += 1 }
            }
        }.value
    }
}
