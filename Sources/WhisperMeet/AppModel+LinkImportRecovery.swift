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
        /// The download's conversion was still running when the launch stopped waiting for it (F912):
        /// index nothing now; `finishDeferredLinkImportConversion` adds the meeting when it ends.
        case converting(Task<URL, Error>, download: URL)
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
            case let .converting(task):
                return .converting(task, download: download)
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
        case let .converting(task):
            return .converting(task, download: download)
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

    /// Removes the WAV ffmpeg never finished from a recovered link import's folder, once the meeting
    /// is indexed from the complete download beside it (F894). Startup recovery calls it after the
    /// sweep has saved the index, for every link import `settleInterruptedLinkImport` decided.
    ///
    /// Recovery used to delete nothing, so that WAV — gigabytes for a multi-hour import — stayed in
    /// the folder, counted against the meeting until it was deleted. It is removed only when all of
    /// these hold, and kept otherwise:
    /// - the meeting is made from the download, not from the WAV. A meeting made from its WAV keeps
    ///   the download beside it: both are complete, and recovery never deletes a complete copy
    ///   (Shrink removes the download when it can show the recording covers it, F911, F947);
    /// - both are measured, and the WAV holds less than the download by more than `lengthTolerance`:
    ///   the download with the reader Shrink uses (F948), the WAV by what its complete header declares
    ///   or, when ffmpeg never finished it, by the audio its bytes hold (`heldWAVSeconds`). Not on the
    ///   premise that an unfinished WAV holds less: on the path where the conversion has just failed,
    ///   the download may be unreadable, and the WAV then the only audio anything has decoded (review
    ///   of F894, finding 1). A download that cannot be measured keeps the WAV;
    /// - the kernel says no process has the WAV or the download open (F946). An answer it cannot give
    ///   keeps the file, which costs disk space and nothing else;
    /// - it is still the file that was measured (`InterruptedLinkImportExtraction.removeIfUnchanged`):
    ///   another copy of WhisperMeet can rename a finished WAV over the name in the meantime (finding 3).
    func removeUnfinishedExtraction(of meeting: MeetingRecord) async {
        let recording = store.recordingURL(for: meeting)
        let folder = recording.deletingLastPathComponent()
        let wav = folder.appendingPathComponent("\(MediaDownloadArguments.outputBasename).wav")
        guard recording.lastPathComponent != wav.lastPathComponent,
              let download = InterruptedLinkImportExtraction.download(in: folder),
              download.lastPathComponent == recording.lastPathComponent,
              let measured = InterruptedLinkImportExtraction.FileIdentity(of: wav) else { return }
        let downloadSeconds = await linkImportDownloadSeconds(download, estimate: 0)
        guard downloadSeconds > 0,
              let held = InterruptedLinkImportExtraction.heldWAVSeconds(at: wav),
              InterruptedLinkImportExtraction.holdsLess(held, than: downloadSeconds) else { return }
        let probe = importFileOpenState
        let closed = await Task.detached(priority: .utility) {
            probe(wav) == .notHeld && probe(download) == .notHeld
        }.value
        guard closed else { return }
        InterruptedLinkImportExtraction.removeIfUnchanged(wav, identity: measured)
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
    /// cannot disagree about one file. For a file with no length header AVAudioFile's length matched a
    /// full decode (60.029 s both, in that review), so it may read the whole file, and it is asked off
    /// the main actor. Only a file AVAudioFile cannot open falls back to `estimate`
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
        /// Still running when the launch stopped waiting for it (F912).
        case converting(Task<URL, Error>)
    }

    /// Runs `finishInterruptedLinkImportExtraction` and measures its result; a result AVFoundation
    /// cannot measure counts as a failed conversion.
    ///
    /// The launch waits `linkImportConversionWait` for it (F912). A conversion still running then is
    /// not stopped — `0da8039` killed it and listed the import as unfinished, whose remedy is a second
    /// download of something complete on disk — but left running, and handed back for
    /// `finishDeferredLinkImportConversion` to index when it ends. Its own expiry is its output
    /// (`linkImportConversionStallLimit`, in the seam's default).
    ///
    /// A finished conversion is a measurement of the download too: the WAV holds all of it. So its
    /// length is recorded beside the download (`InterruptedLinkImportExtraction.recordConversion`),
    /// which is how Shrink can show the recording covers a WebM that AVFoundation cannot read, and
    /// remove it (F947). Without the record such a meeting was never shrunk.
    private func convertInterruptedLinkImportDownload(_ download: URL) async -> LinkImportConversion {
        let finish = finishInterruptedLinkImportExtraction
        let conversion = Task { try await finish(download) }
        // F961: held from now until it ends, so Quit reaches it while the launch is still waiting for
        // it — a free task nothing holds is one a quit cannot cancel, and its ffmpeg outlived the app.
        let token = UUID()
        runningLinkImportConversions[token] = conversion
        let wait = linkImportConversionWait
        // Whichever ends first: the conversion, or the wait. Not a task group — a group waits for
        // every child before it returns, and a child awaiting `conversion.result` cannot be
        // cancelled, so a group made the launch wait for the whole conversion after all (the first
        // cut of F912 did, and its tests passed only because their stubs ended on their own). Two
        // free tasks race for one continuation instead; the loser finishes later and resumes nothing.
        let ended = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let first = FirstToFinish()
            Task { [weak self] in
                _ = await conversion.result
                // On the main actor, as this method is: the conversion is let go only once it has ended.
                self?.runningLinkImportConversions[token] = nil
                if first.claim() { continuation.resume(returning: true) }
            }
            Task {
                try? await Task.sleep(for: .seconds(wait))
                if first.claim() { continuation.resume(returning: false) }
            }
        }
        guard ended else { return .converting(conversion) }
        return await settleConversion(conversion.result, of: download)
    }

    /// Lets exactly one of two racing tasks resume a continuation (F912).
    private final class FirstToFinish: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.withLock {
                defer { claimed = true }
                return !claimed
            }
        }
    }

    /// What a conversion's end means for the import: measured and recorded, failed, or cancelled.
    private func settleConversion(_ result: Result<URL, Error>, of download: URL) async -> LinkImportConversion {
        switch result {
        case let .success(finished):
            let measured = await Self.loadDuration(of: finished)
            guard measured > 0 else { return .failed(MediaDownloadError.extractionFailed.localizedDescription) }
            InterruptedLinkImportExtraction.recordConversion(of: download, seconds: measured)
            return .converted(finished, measured)
        case .failure(is CancellationError):
            return .cancelled
        case let .failure(error):
            return .failed(error.localizedDescription)
        }
    }

    /// Adds the meeting of a link import whose conversion outlasted the launch's wait, once that
    /// conversion ends (F912): from the finished WAV as the sweep would have, or as an unfinished
    /// import when it could not be finished. Says so through `report`, as the sweep's notice does
    /// (F257). A cancelled conversion — a quit — indexes nothing, so the next launch finds the folder
    /// as it was; so does one that ends after the library stopped accepting changes, or after
    /// something else indexed the folder.
    func finishDeferredLinkImportConversion(
        orphan: OrphanedRecording, download: URL, conversion: Task<URL, Error>,
        mediaSource: MediaSource, provenanceTags: [String]?
    ) async {
        let settled = await settleConversion(conversion.result, of: download)
        // A quit cancels this task (`cancelWorkForQuit`): nothing is indexed even if the conversion
        // had just finished, so the next launch finds the folder, WAV and all, and decides itself.
        guard !Task.isCancelled, !store.isDegraded, !store.isRestoringLibrary, store.meeting(id: orphan.id) == nil else { return }
        switch settled {
        case .cancelled, .converting:
            return
        case let .failed(reason):
            report(indexUnfinishedLinkImport(
                orphan: orphan, download: download, reason: reason,
                mediaSource: mediaSource, provenanceTags: provenanceTags
            ))
        case let .converted(finished, seconds):
            report(indexConvertedLinkImport(
                orphan: orphan, finished: finished, seconds: seconds,
                mediaSource: mediaSource, provenanceTags: provenanceTags
            ))
            if let meeting = store.meeting(id: orphan.id) { await removeUnfinishedExtraction(of: meeting) }
        }
    }

    /// Lists a link import whose conversion could not be finished (F453): the download as its
    /// recording, with why, and never a suggestion to delete the entry. Returns the notice.
    func indexUnfinishedLinkImport(
        orphan: OrphanedRecording, download: URL, reason: String,
        mediaSource: MediaSource, provenanceTags: [String]?
    ) -> String {
        let failedTitle = Self.unfinishedLinkImportTitle(host: mediaSource.host)
        let message = Self.unfinishedLinkImportMessage(reason: reason)
        store.upsert(MeetingRecord(
            id: orphan.id,
            title: failedTitle,
            createdAt: orphan.createdAt,
            recordingPath: store.relativeRecordingPath(for: download),
            status: .failed,
            errorMessage: message,
            tags: provenanceTags,
            recoverySource: RecoveredRecording.Source.importedRecording.rawValue,
            source: mediaSource
        ))
        return "\(failedTitle) needs attention. \(message)"
    }

    /// Adds the meeting of a link import from the WAV its deferred conversion made (F912) — the record
    /// `performStartupRecovery`'s sweep writes for a recovered import that is not truncated, read
    /// from the same sidecar: a link import has no capture session, so its title is the synthesized
    /// one unless a session says otherwise, and it carries no markers or sleep. Returns the notice.
    private func indexConvertedLinkImport(
        orphan: OrphanedRecording, finished: URL, seconds: TimeInterval,
        mediaSource: MediaSource, provenanceTags: [String]?
    ) -> String {
        let session = RecordingSessionSidecar.read(in: orphan.directory)
        let userTitle = session?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = userTitle.isEmpty
            ? "Recovered Meeting \(orphan.createdAt.formatted(date: .abbreviated, time: .shortened))"
            : userTitle
        let recovered = RecoveredRecording(recordingURL: finished, duration: seconds, source: .importedRecording)
        store.upsert(MeetingRecord(
            id: orphan.id,
            title: title,
            createdAt: orphan.createdAt,
            duration: seconds,
            recordingPath: store.relativeRecordingPath(for: finished),
            errorMessage: "Recovered after an interruption. The original recording and source tracks were preserved.",
            markers: session?.markers.isEmpty == false ? session?.markers : nil,
            tags: provenanceTags,
            recoveryWarning: Self.recoveryWarning(for: recovered),
            recoverySource: recovered.source.rawValue,
            recoveryInterruption: session?.interruptedBySleepAt == nil ? nil : RecoveryInterruption.systemSleep.rawValue,
            source: mediaSource
        ))
        return "\(title) was added back to meeting history."
    }
}
