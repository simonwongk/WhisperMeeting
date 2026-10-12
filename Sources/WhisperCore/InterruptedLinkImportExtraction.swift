import Foundation

/// Finishes the audio extraction a link import was interrupted in (F453).
///
/// yt-dlp downloads a link's audio in whatever format the site serves — for YouTube usually Opus in
/// WebM — and then has ffmpeg convert it into `recording.wav` (`MediaDownloadArguments.download`).
/// An import interrupted during that conversion leaves the complete download beside a half-written
/// WAV, and recovery prefers the download (`InterruptedRecordingRecovery.importedRecordingCandidate`).
/// But AVFoundation cannot open WebM/Opus, and neither can the AudioToolbox path the Qwen engine reads
/// through — which is why the import converts at all — so a download recovered as it is would be
/// listed as audio macOS cannot verify. This runs the conversion yt-dlp was running, with the import's
/// own ffmpeg options, so the recovered meeting is the WAV the import would have produced.
///
/// It writes a temporary file of its own, `recording.extracting.<run>.wav`, and renames it over
/// `recording.wav` (the half-written one) only once ffmpeg has exited cleanly. So an interruption of
/// this run leaves what it found, plus a partial temp file that is never a recovery candidate (its
/// stem is not `recording`) and that the liveness probe still sees grow if this ffmpeg outlives the
/// app too (its name starts `recording.`). **The download is never touched**, on success or failure.
/// A failure removes the temp file and throws; cancellation is rethrown as it is, so the caller can
/// leave the folder for the next launch.
///
/// **One temp file per run, held for the run (F945).** Two app instances whose library lease cannot
/// tell them apart (`.unavailable`, `.unmanaged`) can both convert one interrupted import. With one
/// temp name for every run, the run that started second removed the first one's temp as stale and
/// wrote its own under the same name, and the first run, exiting first, then found a file by that
/// name and renamed the second one's unfinished output into place. Now each run renames only the
/// file it created, and holds an exclusive `flock` on it from the moment it creates it (`O_EXLOCK`,
/// one step) until it has renamed or removed it. The sweep that clears what a quit, crash or kill
/// left behind removes only a temp file whose lock it can take, which is one no run in any process
/// is holding: the kernel releases a dead process's lock, so an abandoned file is always free, and a
/// running one never is. Two runs that both finish leave the folder holding whichever renamed last,
/// and both are complete conversions of the same download with the same options.
///
/// A run still going when its `timeLimit` passes is killed — SIGKILL to its process group
/// (`ProcessGroupRunner.kill()`) — and throws `extractionTimedOut`. Not the SIGTERM a cancellation
/// sends: the runner waits for the process without a bound, and ffmpeg 8.1.2 whose input read is
/// blocked does not exit on one SIGTERM (measured with this conversion's own vector: still running
/// 17.3 s after it), so a limit it could ignore was no limit. Nothing is lost by not stopping it
/// gracefully, because a stopped run's output is removed, never renamed into place. The limit is a
/// clock, not the runner's stall watchdog: ffmpeg 8 keeps printing progress while its input has
/// stopped arriving (measured with 8.1.2: sixteen reports in eight seconds, all at one `time=`), and
/// any output resets that watchdog, so a stuck conversion would otherwise never end.
public enum InterruptedLinkImportExtraction {
    /// How every file the conversion writes until it has finished is named: each run's own
    /// `recording.extracting.<run>.wav` (F945), and the single `recording.extracting.wav` that builds
    /// before it wrote.
    public static let temporaryFilenamePrefix = "\(MediaDownloadArguments.outputBasename).extracting"

    /// Whether `name` is a conversion's temporary file, this build's or an earlier one's.
    public static func isTemporaryFile(named name: String) -> Bool {
        name.hasPrefix(temporaryFilenamePrefix + ".") && name.lowercased().hasSuffix(".wav")
    }

    /// The temporary file of one run (F945).
    static func temporaryFilename(forRun run: UUID) -> String {
        "\(temporaryFilenamePrefix).\(run.uuidString).wav"
    }

    /// Converts `download` into `recording.wav` beside it and returns that file's URL.
    ///
    /// - Parameter ffmpeg: the executable, or nil when none is installed (`ffmpegMissing`).
    /// - Parameter timeLimit: the longest the conversion may run, or nil for no limit.
    public static func finish(
        download: URL,
        ffmpeg: URL?,
        stallTimeout: TimeInterval = MediaDownloadClient.defaultStallTimeout,
        timeLimit: TimeInterval? = nil
    ) async throws -> URL {
        guard let ffmpeg else { throw MediaDownloadError.ffmpegMissing }
        let directory = download.deletingLastPathComponent()
        let output = directory.appendingPathComponent("\(MediaDownloadArguments.outputBasename).wav")
        removeAbandonedTemporaryFiles(in: directory)
        let temporary = directory.appendingPathComponent(temporaryFilename(forRun: UUID()))
        // Created and locked in one step (`O_EXLOCK`), and held until it is renamed into place or
        // removed, so no other run's sweep takes it for abandoned. ffmpeg's `-y` writes into this
        // same file. `O_CLOEXEC`, so ffmpeg does not inherit the lock.
        let claim = open(temporary.path, O_RDWR | O_CREAT | O_EXCL | O_EXLOCK | O_NONBLOCK | O_CLOEXEC, 0o644)
        guard claim >= 0 else { throw MediaDownloadError.extractionFailed }
        defer { AdvisoryLockDescriptor.unlockAndClose(claim) }
        let runner = ProcessGroupRunner()
        let limit = TimeLimitWatch()
        // Timed on the monotonic uptime, so a clock change at launch cannot move it.
        let watch = timeLimit.map { seconds in
            Task.detached {
                let start = ProcessInfo.processInfo.systemUptime
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if Task.isCancelled { return }
                    if ProcessInfo.processInfo.systemUptime - start >= seconds {
                        limit.markReached()
                        runner.kill()
                        return
                    }
                }
            }
        }
        defer { watch?.cancel() }
        do {
            let outcome: ProcessGroupRunner.Outcome
            do {
                outcome = try await runner.run(
                    executableURL: ffmpeg,
                    arguments: MediaDownloadArguments.finishExtraction(input: download.path, output: temporary.path),
                    environment: MediaDownloadClient.makeEnvironment(),
                    stallTimeout: stallTimeout
                )
            } catch let error as ProcessGroupRunnerError {
                switch error {
                case .spawnFailed: throw MediaDownloadError.ffmpegMissing
                case .stalled: throw MediaDownloadError.extractionFailed
                }
            } catch is CancellationError where limit.wasReached {
                // The watch's cancel, not the caller's: a caller's cancellation is rethrown as it is.
                throw MediaDownloadError.extractionTimedOut(timeLimit ?? 0)
            }
            // Non-empty, not merely present: this run created the file before ffmpeg started.
            let written = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard outcome.exitStatus == 0, written > 0 else {
                throw MediaDownloadError.extractionFailed
            }
            // One atomic step from "half-written" to "finished": rename(2) replaces the old WAV.
            guard rename(temporary.path, output.path) == 0 else { throw MediaDownloadError.extractionFailed }
            return output
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}

extension InterruptedLinkImportExtraction {
    /// Removes every temporary file in `directory` that no conversion is writing: the ones a quit, a
    /// crash or a kill left behind (F945). A running conversion holds its file's lock from creating
    /// it until it has renamed or removed it, in whatever process it runs, and the kernel releases a
    /// dead process's lock. So a file whose lock this can take has no run left to finish it, and one
    /// whose lock is held is left alone, as is one this cannot open. The single name earlier builds
    /// wrote carries no lock, so it always reads as abandoned.
    static func removeAbandonedTemporaryFiles(in directory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where isTemporaryFile(named: name) {
            let path = directory.appendingPathComponent(name).path
            let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { unlink(path) }
            AdvisoryLockDescriptor.unlockAndClose(descriptor)
        }
    }
}

/// Whether a run's time limit has passed: set by the watch, read once the run has ended.
private final class TimeLimitWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var reached = false

    func markReached() {
        lock.lock()
        reached = true
        lock.unlock()
    }

    var wasReached: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reached
    }
}

// MARK: - What an interrupted link import's folder holds beside the file recovery chose (F911)

extension InterruptedLinkImportExtraction {
    /// How far apart two lengths of the same audio may be and still count as the same: the length
    /// macOS reads for a link import's download and the length of the WAV the import's ffmpeg vector
    /// makes from it. Recovery and Shrink both read the download with AVAudioFile (F948). Measured on
    /// 7 s sines made with ffmpeg 8.1.2 (review of F911): AVAudioFile read 7.000 s of AAC in M4A,
    /// 7.032 s of MP3 and 7.000 s of Opus in Ogg, against 7.019, 7.000 and 7.000 s for the WAV made
    /// from each — at most 32 ms apart (WebM cannot be read at all); `afinfo` found the same 32 ms at
    /// 1,801 s. Half a second leaves fifteen times that, and it is the margin Shrink already allows a
    /// compressed copy against its original.
    public static let lengthTolerance: TimeInterval = 0.5

    /// The complete download a link import's folder holds: its non-empty `recording.<ext>` that is not
    /// a WAV, first by name — the order `InterruptedRecordingRecovery.importedRecordingCandidate`
    /// picks a download in. yt-dlp deletes it only once ffmpeg's extraction has finished, so an
    /// interrupted extraction leaves it beside the WAV. Nil when there is none.
    public static func download(in folder: URL) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return nil }
        return contents
            .filter { url in
                guard url.deletingPathExtension().lastPathComponent == MediaDownloadArguments.outputBasename,
                      !url.pathExtension.isEmpty, url.pathExtension.lowercased() != "wav",
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
                    return false
                }
                return values.isRegularFile == true && (values.fileSize ?? 0) > 0
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    /// One file as it was when it was measured: the volume and inode that name it, its size and when
    /// its contents last changed (F894). Equal only for the same file, unchanged.
    public struct FileIdentity: Sendable, Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int

        /// The file at `url` now, or nil when it cannot be stat'ed. A symbolic link is described, not
        /// followed.
        public init?(of url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
        }
    }

    /// Removes `url` only if it is still the file `identity` describes, and returns whether it did
    /// (review of F894, finding 3).
    ///
    /// A removal by path removes whatever has that name by then. Recovery measures a link import's
    /// `recording.wav`, then asks the kernel about it, which takes a moment, and another copy of
    /// WhisperMeet finishing its own conversion (F945) can rename a finished WAV over that name in
    /// between. So the file is first renamed out of the way to a name only this call uses — one
    /// atomic step that takes whatever is there — and removed only if that is the measured file.
    /// Anything else is put back, and never over a file that has taken the name since; if putting it
    /// back fails, it stays under the hidden name, so nothing that was not measured is ever removed.
    @discardableResult
    public static func removeIfUnchanged(_ url: URL, identity: FileIdentity) -> Bool {
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).removing-\(UUID().uuidString)")
        guard rename(url.path, aside.path) == 0 else { return false }
        if FileIdentity(of: aside) == identity, unlink(aside.path) == 0 { return true }
        _ = renamex_np(aside.path, url.path, UInt32(RENAME_EXCL))
        return false
    }

    /// The length a WAV's complete header declares, or nil when it is not a finished WAV.
    public static func finishedWAVSeconds(at url: URL) -> TimeInterval? {
        InterruptedRecordingRecovery.finalizedDuration(at: url)
    }

    /// The seconds of audio a WAV actually holds: what its complete header declares, or, for one
    /// ffmpeg has not finished, what its bytes so far amount to. Nil when its header cannot be read.
    public static func heldWAVSeconds(at url: URL) -> TimeInterval? {
        if let seconds = finishedWAVSeconds(at: url) { return seconds }
        guard let header = WAVInspection.header(at: url), header.bytesPerSecond > 0,
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
        else { return nil }
        let held = size > UInt64(header.dataOffset) ? size - UInt64(header.dataOffset) : 0
        return Double(held) / Double(header.bytesPerSecond)
    }

    /// Whether `seconds` of audio falls short of `downloadSeconds` by more than `lengthTolerance`.
    public static func holdsLess(_ seconds: TimeInterval, than downloadSeconds: TimeInterval) -> Bool {
        seconds < downloadSeconds - lengthTolerance
    }
}

// MARK: - How long a download macOS cannot measure is, once recovery has converted it (F947)

extension InterruptedLinkImportExtraction {
    /// What recovery writes beside a link import's download when it has converted all of it itself:
    /// the download, by name and size, and the length of its conversion — which is the length of the
    /// download's audio, measured the only way the app can measure a WebM (F947).
    public struct ConvertedDownload: Codable, Sendable, Equatable {
        /// The download's name in the meeting's folder.
        public var download: String
        /// Its size when it was converted. A file of another size is not the one that was converted.
        public var downloadBytes: Int64
        /// The length of the WAV the conversion made from it.
        public var seconds: TimeInterval

        public init(download: String, downloadBytes: Int64, seconds: TimeInterval) {
            self.download = download
            self.downloadBytes = downloadBytes
            self.seconds = seconds
        }
    }

    /// The record's name in the meeting's folder. Not `recording.*`, so no recovery, liveness or
    /// Shrink rule takes it for audio, and Shrink leaves it in place.
    public static let convertedDownloadFilename = "download-conversion.json"

    /// Records that `download` was converted in full into audio `seconds` long (F947). Best effort:
    /// a record that cannot be written leaves Shrink unable to show the recording covers the
    /// download, which keeps the download — the state before the record existed.
    public static func recordConversion(of download: URL, seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0,
              let bytes = (try? FileManager.default.attributesOfItem(atPath: download.path)[.size] as? NSNumber)?.int64Value,
              let data = try? JSONEncoder().encode(ConvertedDownload(
                  download: download.lastPathComponent, downloadBytes: bytes, seconds: seconds
              ))
        else { return }
        try? data.write(
            to: download.deletingLastPathComponent().appendingPathComponent(convertedDownloadFilename),
            options: .atomic
        )
    }

    /// The length of `download`'s audio as recovery's own conversion of all of it measured, or nil
    /// unless the folder's record names this file at its present size (F947). Fail-closed: a missing,
    /// unreadable or stale record measures nothing, so Shrink keeps the download.
    public static func convertedSeconds(of download: URL) -> TimeInterval? {
        let recordURL = download.deletingLastPathComponent().appendingPathComponent(convertedDownloadFilename)
        guard let data = try? Data(contentsOf: recordURL),
              let record = try? JSONDecoder().decode(ConvertedDownload.self, from: data),
              record.download == download.lastPathComponent, record.seconds.isFinite, record.seconds > 0,
              let bytes = (try? FileManager.default.attributesOfItem(atPath: download.path)[.size] as? NSNumber)?.int64Value,
              bytes == record.downloadBytes
        else { return nil }
        return record.seconds
    }
}
