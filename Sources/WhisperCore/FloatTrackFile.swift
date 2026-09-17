import Foundation

/// The raw float32 track a recording is captured into, and the durability rules that govern it
/// (F276, made observable by F278).
///
/// This is the second half of what `AudioCaptureEngine.FloatTrackWriter` used to do alone. That
/// type's `append` takes a `CMSampleBuffer`, so the format conversion and the write path were
/// welded together and neither could be tested without a live `SCStream` — which is why F276 shipped
/// its periodic `F_FULLFSYNC` with "the sync happens" resting on the code being three lines long.
/// The conversion stays in `AudioCaptureEngine`, where the AVFoundation types belong; the file, the
/// byte accounting and the flush cadence live here, where a test can watch them.
///
/// Durability, and why it is shaped this way:
///
/// - **Periodically**, every `syncIntervalBytes`, so a kernel panic or a hard power cut loses at
///   most that much of the tail rather than whatever the page cache had not checkpointed yet.
/// - **Once more at `finish()`**, before the mixer reads the tracks back. `FloatTrackMixer` writes
///   the WAV header *last*, so a truncated `meeting.wav` fails `wavDuration` and recovery falls
///   back to these `.f32` files. Their durability is precisely what that fallback rests on.
///
/// Neither alone is enough: without the periodic flush a panic mid-recording takes an unbounded
/// tail, and without the one at `finish` the last partial interval is never durable — and a
/// recording does not end on an interval boundary.
public final class FloatTrackFile {
    /// Flushes a file descriptor to the storage device. Injected so the flush is observable.
    public typealias DeviceSync = (Int32) -> Void

    /// `F_FULLFSYNC`, not `fsync` (F276).
    ///
    /// Plain `fsync` measured 0.01 ms here against `F_FULLFSYNC`'s 3.3 ms median. That gap is not a
    /// bargain, it is the tell: `fsync` hands the data to the drive and returns without waiting for
    /// the drive's own write cache to be flushed, so it buys nothing durable while appearing to cost
    /// nothing. It is exactly what will tempt the next person optimising this path.
    ///
    /// The result is discarded deliberately. A flush that fails leaves exactly the exposure that
    /// existed before F276, and must never fail a capture that is otherwise working — losing a whole
    /// meeting to protect its last five seconds is the wrong trade.
    public static let fullFsync: DeviceSync = { descriptor in
        _ = fcntl(descriptor, F_FULLFSYNC)
    }

    /// The capture path's cadence: ~5 s of 48 kHz mono float32, i.e. 960 KB per track.
    ///
    /// F259 declined this fix believing `F_FULLFSYNC` costs "tens to hundreds of milliseconds" and
    /// would stall the `sampleHandlerQueue` into dropping buffers. Measured on this machine that was
    /// wrong: median 3.32 ms / p99 7.42 ms idle, median 3.45 ms / p99 10.55 ms against a concurrent
    /// 3 GB write. Ten milliseconds every five seconds is affordable on the capture queue.
    ///
    /// Five seconds is a judgement, not an optimum — it bounds tail loss at that cost, and nothing
    /// was measured to say 2 s or 10 s is better. It is also this Mac's internal SSD; a slow
    /// external volume, which a library can live on, may behave very differently.
    public static let captureSyncIntervalBytes = 48_000 * MemoryLayout<Float>.size * 5

    public let url: URL
    /// Frames actually written — the length recovery and the mixer both work from.
    public private(set) var frameCount: Int64 = 0

    /// Whether the track has been finalized or discarded. `append` ignores writes once it is, and
    /// the capture path reads it to skip the format conversion entirely rather than convert a buffer
    /// it is about to drop — that conversion allocates and runs on the `sampleHandlerQueue`.
    public private(set) var isFinished = false

    private let handle: FileHandle
    private let syncIntervalBytes: Int
    private let sync: DeviceSync
    private var bytesSinceSync = 0

    public init(
        url: URL,
        syncIntervalBytes: Int = FloatTrackFile.captureSyncIntervalBytes,
        sync: @escaping DeviceSync = FloatTrackFile.fullFsync
    ) throws {
        self.url = url
        self.syncIntervalBytes = syncIntervalBytes
        self.sync = sync
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    /// Whether enough has accumulated since the last flush to warrant another.
    public static func shouldSync(bytesSinceSync: Int, interval: Int) -> Bool {
        bytesSinceSync >= interval
    }

    /// Appends `frameCount` frames of little-endian float32 from `samples`.
    ///
    /// Takes a pointer because the capture path hands over `AVAudioPCMBuffer.floatChannelData`, and
    /// copying it into an array first would allocate on the `sampleHandlerQueue` for every buffer.
    public func append(_ samples: UnsafePointer<Float>, frameCount frames: Int) throws {
        guard !isFinished, frames > 0 else { return }
        let byteCount = frames * MemoryLayout<Float>.size
        try ThrowingFileHandleIO.write(Data(bytes: samples, count: byteCount), to: handle)
        frameCount += Int64(frames)
        bytesSinceSync += byteCount
        if FloatTrackFile.shouldSync(bytesSinceSync: bytesSinceSync, interval: syncIntervalBytes) {
            // Once per call, not once per interval crossed. A write larger than the interval is
            // already covered: `F_FULLFSYNC` flushes everything written to the descriptor so far,
            // so a second call in the same breath would cost another few milliseconds and flush
            // nothing new.
            sync(handle.fileDescriptor)
            // **Subtract, don't zero.** Zeroing discards up to a full interval of credit on every
            // flush, so the cadence drifts later and later — invisible on the capture path, where a
            // buffer is ~16 KB against a 960 KB interval, but not once `appendSilence` writes 32 KB
            // chunks or a caller hands over a large block. Decrementing keeps the bound this rule
            // exists to provide: at most `syncIntervalBytes` unflushed at any moment.
            // Some of it is also the whole of "periodic" — without any decrement every later write
            // would flush, turning 10 ms per five seconds into 10 ms per buffer, which is the
            // dropout F259 feared reached by accident rather than by decision.
            bytesSinceSync %= syncIntervalBytes
        }
    }

    /// Writes `frames` of silence, in chunks, participating in the same flush cadence.
    ///
    /// This is how F275 pads a gap the capture could not record — a lid close, a sleep — so that
    /// `sample offset == elapsed time` stays true and every timestamp after the gap still means what
    /// it says. Without it, resuming into the same track butt-splices the gap away and shifts the
    /// rest of the meeting invisibly, which is F151.
    ///
    /// Chunked rather than one allocation: the policy's cap is five minutes, i.e. 14.4 M frames, and
    /// materialising that would be a 57 MB spike per track on the capture path.
    public func appendSilence(frames: Int64) throws {
        guard !isFinished, frames > 0 else { return }
        let chunk = [Float](repeating: 0, count: min(Int(frames), FloatTrackFile.silenceChunkFrames))
        var remaining = frames
        while remaining > 0 {
            let count = Int(min(remaining, Int64(chunk.count)))
            try chunk.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                try append(base, frameCount: count)
            }
            remaining -= Int64(count)
        }
    }

    /// 8,192 frames — one 32 KB write, matching `FloatTrackMixer`'s read chunk.
    private static let silenceChunkFrames = 8_192

    public func append(_ samples: [Float]) throws {
        try samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            try append(base, frameCount: buffer.count)
        }
    }

    /// Flushes the tail and closes the file. Idempotent.
    ///
    /// Idempotence is load-bearing, not tidiness: on the capture path `preservePartialTracks()`
    /// finalizes both tracks on every abort route and the normal stop finalizes them again, so
    /// `finish` is genuinely called twice. A second flush would be aimed at a closed descriptor,
    /// which in the worst case has already been reused by another open file.
    public func finish() throws {
        guard !isFinished else { return }
        // Flush first, while the descriptor is still open.
        sync(handle.fileDescriptor)
        // Marked finished *before* the close, so a throwing close does not invite a retry. This
        // differs from the code F278 replaced, deliberately: the flush above has already happened,
        // so the bytes are durable whether or not the close succeeds, and after a failed `close()`
        // the descriptor's state is undefined — closing it again is the one thing not worth trying.
        isFinished = true
        try handle.close()
    }

    /// Discards the track — for a capture that never became a recording.
    public func cancel() {
        isFinished = true
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }
}
