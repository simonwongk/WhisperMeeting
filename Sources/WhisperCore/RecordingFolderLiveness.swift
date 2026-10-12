import Foundation

/// Whether a recording folder is being written to right now (F279).
///
/// This closes F255's residual gap. That ticket's gate rests on "a live second instance never
/// holds the lease", which covers a recorder holding `.held` — not one holding *neither*, which
/// happens because `MeetingStore.writerLease` is sampled once in `init` and never refreshed. A
/// holds the lease and quits; B still believes `.heldElsewhere` for the rest of its life; B
/// records on no lease at all; C launches, acquires `.held`, the gate opens, and C rebuilds B's
/// live folder. F255 verbatim, not the delayed-recovery trade-off its design accepted.
///
/// **Two samples, not a freshness window.** A live capture appends frames continuously — the
/// callback delivers buffers whether or not anyone is speaking, so a silent room still grows the
/// file — and a crashed one never grows at all. Comparing two samples needs no constant, and gives
/// the property a window cannot: a folder that died reads as dead *however soon you look*, so a
/// user relaunching seconds after a crash still gets their recording back. A window would have had
/// to be long enough to survive a stream outage F275 restarts and short enough not to defer a
/// fresh crash, and those pull opposite ways.
///
/// **Known residual, and it is bigger than this comment first claimed (F283).** A capture inside an
/// outage F275 intends to resume is not growing, so a second instance sweeping in that window sees
/// a dead-looking folder. The original note said "bounded by F275's retry", which is true of the
/// stream-failure trigger (~1 s) and **false of the sleep trigger**, where the gap is the sleep
/// itself and the cap is `CaptureRestartPolicy.defaultMaximumPaddedGap` — five minutes. A Mac
/// asleep for four minutes, a second instance launched on wake, and this probe rebuilds a live
/// recording. The lease gate does not cover it: that instance is a first launch and takes the
/// lease legitimately.
///
/// Closing it needs a positive assertion from the writer — no static signal distinguishes a
/// mid-gap folder from a crashed one, which is F255's own observation and the reason this asks
/// about change over time at all. F283 carries the design; do not widen this into a time window,
/// which is the thing it was built to avoid.
public enum RecordingFolderLiveness {
    private static let trackNames = ["system-audio.f32", "microphone-audio.f32"]

    /// What a link import writes (F453): yt-dlp's `recording.<ext>.part` while it downloads, then
    /// `recording.<ext>`, then ffmpeg's `recording.wav` while it extracts — and recovery's own
    /// conversion writes `recording.extracting.<run>.wav` (F945). Quit stops yt-dlp and ffmpeg
    /// (`AppModel.cancelWorkForQuit`, F893); a crash sends them no signal, since yt-dlp leads its own
    /// process group and ffmpeg is its child. Measured with yt-dlp 2026.08.19 and ffmpeg 8.1.2 (F893):
    /// during the download yt-dlp dies at its next progress line, within a second, on the app's closed
    /// pipe; during the extraction ffmpeg, writing to yt-dlp's pipes, runs on to the end, and yt-dlp,
    /// waiting for it, then dies when it reports deleting the download — before deleting it
    /// (`YoutubeDL._delete_downloaded_files` prints first). A folder one of them is still writing is as
    /// live as a capture's.
    private static let importFilePrefix = "recording."

    /// The sizes of what is being written, at one instant: the raw tracks, and any import file.
    /// Absent for a file that is not there.
    public struct Sample: Sendable, Equatable {
        public let trackBytes: [String: Int64]

        public init(trackBytes: [String: Int64]) {
            self.trackBytes = trackBytes
        }
    }

    /// Reads both track sizes and every import file's. A pure read: opens nothing, writes nothing,
    /// and never throws — a file it cannot stat is simply absent from the sample, which `isGrowing`
    /// then treats the same as a file that is not there.
    public static func sample(in directory: URL) -> Sample {
        let importFiles = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix(importFilePrefix) }
        var bytes: [String: Int64] = [:]
        for name in trackNames + importFiles {
            let path = directory.appendingPathComponent(name).path
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber else { continue }
            bytes[name] = size.int64Value
        }
        return Sample(trackBytes: bytes)
    }

    /// Whether anything was appended between the two samples.
    ///
    /// Either track growing is enough — one channel can fail while the other keeps recording, and
    /// the folder is live either way. A file that *appears* between samples counts as growth:
    /// a capture that has just started has written one file and not yet the other, and that is the
    /// narrowest window in a recording's life to leave unprotected; an import's download renamed
    /// from its `.part` appears under its new name the same way (F453).
    ///
    /// Shrinking does not count. Nothing in the app truncates a track mid-capture, so that is a
    /// corrupt or externally edited folder rather than a live one, and reading it as live would
    /// defer its recovery forever — the one outcome worse than rebuilding it. A file that
    /// disappears does not count either, for the same reason.
    public static func isGrowing(from before: Sample, to after: Sample) -> Bool {
        after.trackBytes.contains { name, now in
            guard let then = before.trackBytes[name] else { return true }   // absent, then present
            return now > then
        }
    }
}

// MARK: - A positive sign of a writer (F946)

extension RecordingFolderLiveness {
    /// Whether some process has a file open, as the kernel answers it.
    public enum OpenState: Sendable, Equatable {
        /// At least one process has it open.
        case held
        /// The kernel looked through every process it lets this one see, and none has it open.
        case notHeld
        /// The question could not be asked: the file is missing, or could not be looked up.
        case unknown
    }

    /// Whether any process has the file at `path` open — any of this user's processes, this one
    /// included — answered by `proc_listpidspath` (Darwin's libproc), which looks through every
    /// process's open files for that file. Opens made only to watch it for changes (`O_EVTONLY`, as
    /// Finder and FSEvents clients do) do not count, and a process of another user, whose files this
    /// one may not list, is not seen. It opens nothing. Measured on macOS 27: 0.1–0.3 s a call.
    public static func openState(of path: String) -> OpenState {
        var pids = [pid_t](repeating: 0, count: 1_024)
        let bytes = pids.withUnsafeMutableBytes { buffer in
            proc_listpidspath(
                UInt32(PROC_ALL_PIDS), 0, path, UInt32(PROC_LISTPIDSPATH_EXCLUDE_EVTONLY),
                buffer.baseAddress, Int32(buffer.count)
            )
        }
        if bytes < 0 { return .unknown }
        return bytes > 0 ? .held : .notHeld
    }

    /// The import files in `directory` — the `recording.*` names `sample` watches — that some process
    /// has open, in name order (F946).
    ///
    /// Growth between two samples misses a writer that is alive but has stalled for longer than the
    /// samples are apart, and neither yt-dlp nor ffmpeg says "still running" any other way. An open
    /// file does: yt-dlp holds its `.part` while it downloads, and ffmpeg holds the download it reads
    /// and the WAV it writes for as long as it runs, and the kernel closes them when the process ends,
    /// however it ends. So a folder that answers here is live for as long as its writer is, and no
    /// longer. A file whose state is `.unknown` is not counted: that is the answer before this probe
    /// existed, with the growth probe and the library lease still in front of it.
    public static func importFilesHeldOpen(
        in directory: URL,
        openState: (URL) -> OpenState = { RecordingFolderLiveness.openState(of: $0.path) }
    ) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix(importFilePrefix) }
            .sorted()
            .filter { openState(directory.appendingPathComponent($0)) == .held }
    }
}
