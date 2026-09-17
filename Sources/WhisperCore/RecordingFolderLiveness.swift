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
/// **Known residual.** A capture whose stream has died but which F275 is about to restart is not
/// growing during the outage, so a second instance sweeping in exactly that window sees a
/// dead-looking folder. The window is bounded by F275's retry, F255's lease gate still covers the
/// ordinary two-instance case — this is an additional refusal, never a replacement for it — and a
/// freshness window fails worse in a more common case.
public enum RecordingFolderLiveness {
    private static let trackNames = ["system-audio.f32", "microphone-audio.f32"]

    /// The raw tracks' sizes at one instant. `nil` for a track that is not there.
    public struct Sample: Sendable, Equatable {
        public let trackBytes: [String: Int64]

        public init(trackBytes: [String: Int64]) {
            self.trackBytes = trackBytes
        }
    }

    /// Reads both track sizes. A pure read: opens nothing, writes nothing, and never throws — a
    /// track it cannot stat is simply absent from the sample, which `isGrowing` then treats the
    /// same as a track that is not there.
    public static func sample(in directory: URL) -> Sample {
        var bytes: [String: Int64] = [:]
        for name in trackNames {
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
    /// the folder is live either way. A track that *appears* between samples counts as growth:
    /// a capture that has just started has written one file and not yet the other, and that is the
    /// narrowest window in a recording's life to leave unprotected.
    ///
    /// Shrinking does not count. Nothing in the app truncates a track mid-capture, so that is a
    /// corrupt or externally edited folder rather than a live one, and reading it as live would
    /// defer its recovery forever — the one outcome worse than rebuilding it.
    public static func isGrowing(from before: Sample, to after: Sample) -> Bool {
        trackNames.contains { name in
            let then = before.trackBytes[name]
            guard let now = after.trackBytes[name] else { return false }
            guard let then else { return true }   // absent, then present
            return now > then
        }
    }
}
