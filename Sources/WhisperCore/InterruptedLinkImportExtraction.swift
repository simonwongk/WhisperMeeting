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
/// It writes `recording.extracting.wav` and renames it over `recording.wav` (the half-written one)
/// only once ffmpeg has exited cleanly. So an interruption of this run leaves what it found, plus a
/// partial temp file that is never a recovery candidate (its stem is not `recording`) and that the
/// liveness probe still sees grow if this ffmpeg outlives the app too (its name starts `recording.`).
/// **The download is never touched**, on success or failure. A failure removes the temp file and
/// throws; cancellation is rethrown as it is, so the caller can leave the folder for the next launch.
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
    /// Where the conversion writes until it has finished.
    public static let temporaryFilename = "\(MediaDownloadArguments.outputBasename).extracting.wav"

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
        let temporary = directory.appendingPathComponent(temporaryFilename)
        try? FileManager.default.removeItem(at: temporary)
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
            guard outcome.exitStatus == 0, FileManager.default.fileExists(atPath: temporary.path) else {
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
    /// makes from it. Measured with ffmpeg 8.1.2 and `afinfo` on 7 s and 1,801 s sines: 32 ms apart
    /// for MP3, 19 ms for AAC in M4A, 6.5 ms for Opus in Ogg (WebM cannot be read at all). Half a
    /// second leaves fifteen times the widest of those, and it is the margin Shrink already allows a
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
