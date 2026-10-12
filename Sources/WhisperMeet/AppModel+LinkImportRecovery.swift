import Foundation
import WhisperCore

/// Startup recovery's handling of a link import interrupted while ffmpeg extracted its audio (F453,
/// F911). `performStartupRecovery` calls it for a recovered import with a `source.json`. Nothing here
/// deletes, moves or rewrites the download, on any path.
///
/// yt-dlp runs ffmpeg from the complete download straight into `recording.wav` and deletes the
/// download only once ffmpeg has finished, so the folder an interrupted extraction leaves holds both.
/// `InterruptedRecordingRecovery.importedRecordingCandidate` chooses between them from the files
/// alone: a WAV with a complete header first, else the download. That is right for a WAV ffmpeg never
/// finished, whose header keeps 0xFFFFFFFF placeholders. But a complete header is not proof that the
/// extraction finished: ffmpeg stopped by SIGTERM — what a shutdown, restart or logout sends it —
/// finishes the header over the part it had written (measured with ffmpeg 8.1.2: SIGTERM two seconds
/// into an hour's download left a consistent header declaring 1,813 s). So when both are there, the
/// download decides.
extension AppModel {
    /// What startup recovery makes of an interrupted link import's folder.
    enum LinkImportSettlement {
        /// Index this recording, of this length, with this caveat when there is one.
        case recording(RecoveredRecording, duration: TimeInterval, warning: String?)
        /// The download could not be converted: list `recording` (the download) as an unfinished import.
        case unfinished(reason: String, recording: URL)
        /// Cancelled: index nothing, so the next launch finds the folder as it was.
        case leaveForNextLaunch
    }

    /// The caveat on a link import recovered from a WAV that could not be checked against the complete
    /// download beside it (F911). Says why, where the download is and what to do if the recording
    /// stops early; never suggests deleting the entry, which would delete the download with its folder.
    static func uncheckedLinkImportWarning(reason: String) -> String {
        "This link import was interrupted while its audio was being extracted, and this recording could not be checked against the complete download, so it may stop before the end. \(reason) The complete download is kept in this meeting's folder with its link: if the recording stops early, import that link again."
    }

    /// Decides which file an interrupted link import's meeting is made from. `recovered` is what
    /// `InterruptedRecordingRecovery.recover` chose, and `duration` its length: the WAV header's, or
    /// AVFoundation's for a download (0 when it cannot be read).
    func settleInterruptedLinkImport(_ recovered: RecoveredRecording, duration: TimeInterval) async -> LinkImportSettlement {
        let chosen = recovered.recordingURL
        let folder = chosen.deletingLastPathComponent()
        let wavName = "\(MediaDownloadArguments.outputBasename).wav"
        guard let download = InterruptedLinkImportExtraction.download(in: folder) else {
            // A lone file: nothing beside it to weigh it against.
            return .recording(recovered, duration: duration, warning: nil)
        }

        if chosen.lastPathComponent == download.lastPathComponent {
            // F453: the WAV beside the download was never finished, or there is none. The download
            // is the recording, so its length is the meeting's — as Shrink reads it (F948).
            let seconds = await linkImportDownloadSeconds(download, estimate: duration)
            if seconds > 0 {
                return .recording(
                    RecoveredRecording(recordingURL: download, duration: seconds, source: .importedRecording),
                    duration: seconds, warning: nil
                )
            }
            // macOS cannot open it — YouTube's audio is usually Opus in WebM — so the conversion the
            // import was running is finished here, with its own ffmpeg options.
            switch await convertInterruptedLinkImportDownload(download) {
            case .cancelled:
                return .leaveForNextLaunch
            case let .converted(finished, seconds):
                return .recording(
                    RecoveredRecording(recordingURL: finished, duration: seconds, source: .importedRecording),
                    duration: seconds, warning: nil
                )
            case let .failed(reason):
                return .unfinished(reason: reason, recording: download)
            }
        }

        guard chosen.lastPathComponent == wavName else {
            return .recording(recovered, duration: duration, warning: nil)
        }
        // F911: a WAV whose header is complete, beside the complete download.
        let downloadSeconds = await linkImportDownloadSeconds(download, estimate: nil)
        if downloadSeconds > 0 {
            guard InterruptedLinkImportExtraction.holdsLess(duration, than: downloadSeconds) else {
                // The extraction finished, and the app stopped before yt-dlp deleted the download.
                return .recording(recovered, duration: duration, warning: nil)
            }
            // Stopped part way and finished on the way out: the download is the whole import.
            return .recording(
                RecoveredRecording(recordingURL: download, duration: downloadSeconds, source: .importedRecording),
                duration: downloadSeconds, warning: nil
            )
        }
        // macOS cannot measure the download, so it is converted again. `finish` replaces this WAV
        // only with one it has finished, so the old one stays until then.
        switch await convertInterruptedLinkImportDownload(download) {
        case .cancelled:
            return .leaveForNextLaunch
        case let .converted(finished, seconds):
            return .recording(
                RecoveredRecording(recordingURL: finished, duration: seconds, source: .importedRecording),
                duration: seconds, warning: nil
            )
        case let .failed(reason):
            // What is at `recording.wav` now — the old WAV, unless a conversion finished whose result
            // macOS could not measure — is indexed as it was, saying that it could not be checked.
            let wav = folder.appendingPathComponent(wavName)
            guard let seconds = InterruptedLinkImportExtraction.finishedWAVSeconds(at: wav), seconds > 0 else {
                return .unfinished(reason: reason, recording: download)
            }
            return .recording(
                RecoveredRecording(recordingURL: wav, duration: seconds, source: .importedRecording),
                duration: seconds, warning: Self.uncheckedLinkImportWarning(reason: reason)
            )
        }
    }

    /// The import files in `folder` that some process has open (F946), asked of `importFileOpenState`
    /// off the main actor, since each answer looks through every process's open files.
    func importFilesHeldOpen(in folder: URL) async -> [String] {
        let probe = importFileOpenState
        return await Task.detached(priority: .utility) {
            RecordingFolderLiveness.importFilesHeldOpen(in: folder, openState: probe)
        }.value
    }

    /// The length of an interrupted link import's download, read the way Shrink reads it
    /// (`declaredDurationForShrink`, AVAudioFile), or 0 when it cannot be measured (F948).
    ///
    /// Recovery used `loadDuration` here, which is `AVURLAsset` with no options, and that may be an
    /// estimate: a VBR MP3 without a length header and with a loud start read 16.4 s of its 20.0 s on
    /// macOS 27, and the review of F911 measured 41.3 s of 60.0 s. So a WAV ffmpeg finished on SIGTERM,
    /// shorter than the download but longer than the estimate, was indexed as the whole import, while
    /// Shrink, reading the same file exactly, refused to delete it. One reader for both means they
    /// cannot disagree about one file. AVAudioFile counts the packets of a file with no length header,
    /// so it is read off the main actor. Only a file AVAudioFile cannot open falls back to `estimate`
    /// (or to `loadDuration` when the caller has none); Shrink refuses such a file as unmeasured, so
    /// the fallback cannot lead it to delete anything.
    private func linkImportDownloadSeconds(_ download: URL, estimate: TimeInterval?) async -> TimeInterval {
        let reader = declaredDurationForShrink
        let exact = await Task.detached(priority: .utility) { reader(download) }.value
        if let exact, exact.isFinite, exact > 0 { return exact }
        if let estimate { return estimate }
        return await Self.loadDuration(of: download)
    }

    private enum LinkImportConversion {
        case converted(URL, TimeInterval)
        case failed(String)
        case cancelled
    }

    /// Runs `finishInterruptedLinkImportExtraction` (under the launch's time limit) and measures its
    /// result; a result AVFoundation cannot measure counts as a failed conversion.
    private func convertInterruptedLinkImportDownload(_ download: URL) async -> LinkImportConversion {
        do {
            let finished = try await finishInterruptedLinkImportExtraction(download)
            let measured = await Self.loadDuration(of: finished)
            return measured > 0
                ? .converted(finished, measured)
                : .failed(MediaDownloadError.extractionFailed.localizedDescription)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
