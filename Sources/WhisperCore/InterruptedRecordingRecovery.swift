import Foundation

public struct RecoveredRecording: Sendable, Equatable {
    /// How a recovery produced its recording.
    ///
    /// `String`-backed so it can be persisted on the meeting (F273) — provenance kept as prose in
    /// `errorMessage` was erased by the ordinary act of transcribing. Raw-value-backed rather than
    /// stored as a Swift enum so an unfamiliar value from a newer build decodes and is ignored
    /// instead of making the library unreadable, which is F250's rule one file over.
    public enum Source: String, Sendable, Equatable {
        case existingCapture
        case importedRecording
        case rebuiltSourceTracks
    }

    public let recordingURL: URL
    public let duration: TimeInterval
    public let source: Source

    /// Where the rebuild stopped, when a raw track became unreadable partway through (F256).
    /// `nil` for every recovery that read cleanly — its presence means the audio is short.
    public let truncatedAtSeconds: TimeInterval?

    /// What the raw tracks promised, from their file size. Carried so a caller can judge how much
    /// of the meeting survived: `duration` and `truncatedAtSeconds` are EQUAL after a truncation
    /// (both derive from `writtenFrames`), so the ratio cannot be computed without this.
    public let expectedDurationSeconds: TimeInterval?

    public init(
        recordingURL: URL,
        duration: TimeInterval,
        source: Source,
        truncatedAtSeconds: TimeInterval? = nil,
        expectedDurationSeconds: TimeInterval? = nil
    ) {
        self.recordingURL = recordingURL
        self.duration = duration
        self.source = source
        self.truncatedAtSeconds = truncatedAtSeconds
        self.expectedDurationSeconds = expectedDurationSeconds
    }

    public var wasRebuiltFromRawTracks: Bool { source == .rebuiltSourceTracks }

    /// A rebuild that kept less than a tenth of what the tracks promised (F256).
    ///
    /// Such a meeting is upserted `.failed` naming the raw tracks rather than presented as an
    /// ordinary recovery, so "technically recovered" cannot masquerade as recovered. The boundary
    /// is a judgement, not a measurement — it exists because there is no in-app way to re-run
    /// recovery on a folder once it is indexed (F267), so a misleadingly tiny meeting is final.
    public var isSeverelyTruncated: Bool {
        guard let expected = expectedDurationSeconds, expected > 0, truncatedAtSeconds != nil else {
            return false
        }
        return duration < expected / 10
    }
}

public enum InterruptedRecordingRecovery {
    private static let systemFile = "system-audio.f32"
    private static let microphoneFile = "microphone-audio.f32"

    /// Whether this instance may rebuild an interrupted recording folder (F255).
    ///
    /// Refuses exactly one state. While a capture is running its folder is structurally identical
    /// to an interrupted one — `meeting.wav` is written only by `AudioCaptureEngine.stop()` — so a
    /// second instance would rebuild a LIVE folder and strand the recording still being made: the
    /// partial rebuild gets indexed, and the complete `meeting.wav` that arrives afterwards has
    /// nothing pointing at it.
    ///
    /// What the lease discriminates, stated precisely: *another instance is open* versus *no other
    /// instance is open*. Not "recording" versus "died recording". That is enough here, because the
    /// defect requires a live second instance, and a crashed first instance had its lease released
    /// by the kernel — so the relaunch after a crash does hold it and does rebuild. No heartbeat is
    /// needed.
    ///
    /// `.unavailable` fails open on purpose: refusing would permanently disable recovery on a
    /// volume without `flock`, which is worse than the defect. This keeps the lease advisory in
    /// F190's Invariant L sense — the gate defers recovery, it never bricks a library.
    ///
    /// **Invariant this makes safety-critical: never call `LibraryWriterLock.acquire` outside
    /// `shared(for:)`.** Two `flock` acquisitions on one file contend within a single process, and
    /// only `MeetingStore` acquires today, via the memoizing `shared(for:)`, which is why the app
    /// never reports `.heldElsewhere` against itself. A future second acquirer — wiring
    /// `DictationLogStore`, or a session marker for F258 — would not merely mislabel a UI string;
    /// it would disable recovery of the user's own crashed recordings.
    public static func mayRebuildInterruptedRecordings(_ lease: StoreWriterLease) -> Bool {
        switch lease {
        case .heldElsewhere: return false
        case .held, .unavailable, .unmanaged: return true
        }
    }

    /// Whether ONE folder may be rebuilt, given what its capture lock says and what the lease says
    /// (F297). The per-folder answer, layered on the per-library one above rather than replacing it:
    ///
    /// - a live writer is refused whatever the lease says — a refusal F255's gate could not make,
    ///   since it never asked about the folder;
    /// - a lock the writer provably no longer holds vouches for the folder, so it is rebuilt even
    ///   under a rival lease — the case F255 recorded as its accepted trade-off;
    /// - no lock file, or no working `flock`, is no evidence either way, and the F255 rule decides
    ///   exactly as before. This is what keeps F279's ordering: an unforeseen probe failure degrades
    ///   to a deferred recovery, never to a rebuild of a live folder.
    public static func mayRebuild(
        folder probe: RecordingCaptureLock.Probe, lease: StoreWriterLease
    ) -> Bool {
        switch probe {
        case .heldByLiveWriter: return false
        case .released: return true
        case .noLockFile, .unavailable: return mayRebuildInterruptedRecordings(lease)
        }
    }

    /// Removes a recording directory only when it contains no entries at all.
    @discardableResult
    public static func removeIfEmpty(in directory: URL) throws -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return false }
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        guard contents.isEmpty else { return false }
        try fileManager.removeItem(at: directory)
        return true
    }

    /// The finalized recording a folder ALREADY holds, or nil when it holds none. A pure read: it
    /// rebuilds nothing, writes nothing, and creates nothing.
    ///
    /// This is the codebase's single definition of "this recording finished", and two callers depend
    /// on it meaning exactly that. `recover(in:)` uses it to skip the rebuild for a folder that needs
    /// none. `MeetingStore.loadMeetings()` uses it to decide whether an empty index is suspicious:
    /// a folder WITHOUT one of these is an interrupted capture, which is what the rebuild below
    /// exists for — not evidence that the index lost a meeting (F187).
    ///
    /// The three names are the three ways a recording becomes real, and all three are required:
    /// `meeting.wav` is written only by `AudioCaptureEngine.stop()`; `meeting-recovered.wav` is what
    /// a previous rebuild left behind and the meeting the user actually has; `recording.<ext>` is an
    /// import, which never has capture tracks at all. Each is checked the same way the recovery path
    /// checks it — a complete WAV header for the captures, non-empty bytes for the import — so a WAV
    /// truncated mid-mix (its header is written LAST) does not read as finalized.
    public static func finalizedRecording(in directory: URL) -> RecoveredRecording? {
        // The two names carry different provenance, and collapsing them was an understatement in
        // my own F273 work (found by an F191 slice E4 test written for something else).
        //
        // `meeting.wav` is written only by `AudioCaptureEngine.stop()`: a clean capture, channels
        // aligned by presentation timestamp. `meeting-recovered.wav` is what a previous rebuild
        // left behind, so its channels are zero-aligned — which is exactly the caveat F273's
        // provenance sentence exists to state. Reporting both as `.existingCapture` meant a
        // meeting re-indexed from a folder that already held a rebuild got the weaker sentence
        // ("the original recording was preserved") and never the alignment one, while its audio
        // was in fact a rebuild.
        for (name, source) in [
            ("meeting.wav", RecoveredRecording.Source.existingCapture),
            ("meeting-recovered.wav", RecoveredRecording.Source.rebuiltSourceTracks),
        ] {
            let url = directory.appendingPathComponent(name)
            if let duration = wavDuration(at: url) {
                return RecoveredRecording(
                    recordingURL: url,
                    duration: duration,
                    source: source
                )
            }
        }
        // An imported recording keeps a single `recording.<ext>` file and no raw source tracks, so
        // it cannot be rebuilt from `.f32` data — recognize it directly instead of reporting that
        // there was not enough audio.
        if let imported = importedRecording(in: directory) {
            return RecoveredRecording(
                recordingURL: imported,
                duration: wavDuration(at: imported) ?? 0,
                source: .importedRecording
            )
        }
        return nil
    }

    /// Mixes the two raw tracks into 16-bit PCM, stopping at the first unreadable chunk (F256).
    ///
    /// Reads and the write are injected so a genuine I/O error can be simulated — it cannot be
    /// produced with a real file, and revoking permissions mid-read is flaky. The **write** is a
    /// closure too, not just the reads: the loop streams each chunk out as it goes, and returning
    /// the PCM instead would mean holding ~345 MB in memory for a 60-minute meeting.
    ///
    /// Truncation is **returned rather than rethrown**, so the caller can still finalize the
    /// readable prefix. The underlying error travels with it only so `recover` can rethrow it when
    /// NOTHING was readable; the user-facing warning is built from the frame offset alone, because
    /// a raw `NSCocoaErrorDomain` string helps nobody.
    ///
    /// A short read is NOT an error: the two `.f32` files are written independently from one capture
    /// callback, so an abrupt stop leaves them ragged and the shorter one is zero-padded by
    /// `RawFloatReader`. Only a throw truncates.
    static func mixTracks(
        totalFrames: Int64,
        chunkSize: Int64,
        readSystem: (Int) throws -> [Float],
        readMicrophone: (Int) throws -> [Float],
        write: ([Int16]) throws -> Void
    ) rethrows -> (writtenFrames: Int64, truncation: (frame: Int64, error: any Error)?) {
        var writtenFrames: Int64 = 0
        while writtenFrames < totalFrames {
            let count = Int(min(chunkSize, totalFrames - writtenFrames))
            let systemSamples: [Float]
            let microphoneSamples: [Float]
            do {
                systemSamples = try readSystem(count)
                microphoneSamples = try readMicrophone(count)
            } catch {
                // One mixed stream, so it stops where EITHER track became unreadable. Keeping one
                // channel past that point would silently change the mix from two channels to one
                // partway through.
                return (writtenFrames, (writtenFrames, error))
            }
            var pcm = [Int16](repeating: 0, count: count)
            for index in pcm.indices {
                // `FloatTrackMixer.mixedSample`, not a second copy of the gain rule (F278). A
                // rebuild has to sound like the capture it is standing in for, and this is the path
                // where a divergence would go unnoticed — there is no original left to compare to.
                pcm[index] = FloatTrackMixer.mixedSample(
                    system: systemSamples[index],
                    microphone: microphoneSamples[index]
                )
            }
            try write(pcm)
            writtenFrames += Int64(count)
        }
        return (writtenFrames, nil)
    }

    /// Opens one raw track for chunked reading, or reports that it has no frames to read.
    typealias TrackOpener = (URL?) throws -> (Int) throws -> [Float]

    /// Reads a real `.f32` track from disk. The only opener the app ever uses.
    static let fileTrackOpener: TrackOpener = { url in
        let reader = try RawFloatReader(url: url)
        return { try reader.read(frameCount: $0) }
    }

    /// A track's size in bytes: nil when the file is **absent**, a throw when it is present but
    /// unstattable (F280).
    ///
    /// The two are not the same thing and collapsing them is the bug. Absent is legitimate — a
    /// microphone-only or system-only recording is ordinary, and `RawFloatReader(url: nil)` exists
    /// for exactly that. Present-but-unstattable means the rebuild cannot know how long the track
    /// is, and answering 0 turned that into a channel of pure silence with **no truncation
    /// reported**, because no read ever failed. Same conflation F256 fixed one level down.
    typealias SizeLookup = (URL) throws -> Int64?

    /// Stats a real file. The only lookup the app ever uses.
    static let fileSizeLookup: SizeLookup = { url in
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // Deliberately `try`, not `try?`: the existence check above has already separated out the
        // legitimate case, so anything failing here is a racing unlink, a disappearing volume, or
        // EMFILE — none of which mean "this track has no audio".
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return size.int64Value
    }

    public static func recover(
        in directory: URL,
        sampleRate: Double = 48_000
    ) throws -> RecoveredRecording? {
        try recover(
            in: directory,
            sampleRate: sampleRate,
            openTrack: fileTrackOpener,
            sizeOf: fileSizeLookup
        )
    }

    /// The seam, internal and used by exactly one test file.
    ///
    /// It exists because the zero-readable-frames floor below cannot be reached with any real file:
    /// every way of making a file unreadable that is available to a test — `chmod 0o000`, pointing
    /// the name at a directory — fails at `FileHandle(forReadingFrom:)`, so the throw arrives
    /// BEFORE the mix and the floor is never consulted. Production reaches it by a different route
    /// (a bad block in the first chunk of a file that opens fine), which is a route a test cannot
    /// manufacture. Injecting the opener is the smallest thing that makes the branch testable
    /// without changing what the app does: `recover(in:sampleRate:)` above passes the real one.
    static func recover(
        in directory: URL,
        sampleRate: Double,
        openTrack: TrackOpener,
        sizeOf sizeLookup: SizeLookup = InterruptedRecordingRecovery.fileSizeLookup
    ) throws -> RecoveredRecording? {
        if let finished = finalizedRecording(in: directory) {
            // Only a capture gets a manifest: an import has no source tracks to describe.
            if finished.source == .existingCapture {
                // Swallowed on purpose (F280), and this is the one place it is right to. The
                // recording here is already COMPLETE on disk — `finalizedRecording` verified its
                // WAV header. The manifest is descriptive metadata about the raw tracks beside it,
                // and `writeRecoveryManifestIfNeeded` already treats its own absence as a normal
                // state (it skips when one exists). So a stat failure leaves the manifest unwritten
                // rather than written false, and the finished recording is still returned. Throwing
                // would lose a whole meeting to a failure to describe its sidecar files.
                //
                // The rebuild path below does the opposite and throws, because there the frame count
                // decides what gets mixed — a wrong answer silently produces a silent channel.
                try? writeRecoveryManifestIfNeeded(
                    in: directory,
                    sampleRate: sampleRate,
                    alignment: "captured-timeline",
                    sizeOf: sizeLookup
                )
            }
            return finished
        }

        return try rebuildFromSourceTracks(
            in: directory,
            sampleRate: sampleRate,
            openTrack: openTrack,
            sizeOf: sizeLookup
        )
    }

    /// Rebuilds from the raw `.f32` tracks, WITHOUT the "already finalized?" short-circuit above.
    ///
    /// `recover` is the two halves together and stays the only caller on the startup and
    /// failed-stop paths. This half is separate because F267 needs exactly it: re-running recovery
    /// on a folder that by definition already holds a finalized rebuild, which is the case
    /// `recover` is built to skip. Splitting it changes nothing about either existing caller.
    ///
    /// It does NOT decide whether re-running is allowed — `SourceRebuild` owns that, including the
    /// refusal to overwrite a folder holding a real `meeting.wav`. Calling this directly on such a
    /// folder would strand the finished capture, which is F255.
    static func rebuildFromSourceTracks(
        in directory: URL,
        sampleRate: Double = 48_000,
        openTrack: TrackOpener = fileTrackOpener,
        sizeOf sizeLookup: SizeLookup = InterruptedRecordingRecovery.fileSizeLookup
    ) throws -> RecoveredRecording? {
        let fileManager = FileManager.default
        let systemURL = directory.appendingPathComponent(systemFile)
        let microphoneURL = directory.appendingPathComponent(microphoneFile)
        // Throwing here, before the output file is created, is deliberate: nothing has been
        // written yet, so the folder still looks like the interrupted capture it is and the next
        // launch retries the rebuild. That is the same contract F256's truncation path keeps.
        let systemFrames = try frameCount(at: systemURL, sizeOf: sizeLookup)
        let microphoneFrames = try frameCount(at: microphoneURL, sizeOf: sizeLookup)
        let totalFrames = max(systemFrames, microphoneFrames)
        guard totalFrames > 0 else { return nil }

        let outputURL = directory.appendingPathComponent("meeting-recovered.wav")
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        fileManager.createFile(atPath: outputURL.path, contents: nil)
        // Anything that throws from here on leaves a 44-byte stub whose header was never written.
        // `wavDuration` refuses it, so it is not mistaken for a finalized recording, but it is also
        // not a recording — remove it so the folder still looks like the interrupted capture it is
        // and the next launch retries the rebuild. Declared before the close defer so it runs after
        // it (defers are LIFO).
        var rebuildSucceeded = false
        defer { if !rebuildSucceeded { try? fileManager.removeItem(at: outputURL) } }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        // 44 bytes, or 80 when the rebuild is long enough to need RF64 (F302) — matching the mixer.
        let headerLength = WAVWriter.headerLength(dataByteCount: UInt64(max(0, totalFrames)) * 2)
        try ThrowingFileHandleIO.write(Data(repeating: 0, count: headerLength), to: output)

        let readSystem = try openTrack(systemFrames > 0 ? systemURL : nil)
        let readMicrophone = try openTrack(microphoneFrames > 0 ? microphoneURL : nil)
        let mix = try mixTracks(
            totalFrames: totalFrames,
            chunkSize: 8_192,
            readSystem: readSystem,
            readMicrophone: readMicrophone,
            write: { pcm in
                try pcm.withUnsafeBytes { try ThrowingFileHandleIO.write(Data($0), to: output) }
            }
        )
        let writtenFrames = mix.writtenFrames

        // The floor (F256). Nothing readable means nothing to recover, and indexing a duration-0
        // meeting would be strictly worse than failing: `wavDuration` refuses a 44-byte WAV, so the
        // file would not even be recognised as finalized, yet the meeting's UUID would enter
        // `indexedIDs` and `orphanedRecordings()` would exclude the folder permanently — stranding
        // intact `.f32` tracks with no route back, since nothing re-runs recovery on an indexed
        // folder (F267). Throwing hands this to the caller's per-orphan catch, which leaves the
        // folder untouched and reports it.
        if writtenFrames == 0, let truncation = mix.truncation {
            throw truncation.error
        }

        let dataByteCount = UInt64(max(0, writtenFrames)) * 2
        try output.seek(toOffset: 0)
        try ThrowingFileHandleIO.write(
            // `WAVWriter.header`, not a local copy (F278). The header the rebuild writes must be
            // byte-identical to the one a normal capture writes, and F150's overflow fix has to land
            // in one place — this path runs *after* an interruption, so it is the last one that
            // should diverge.
            WAVWriter.header(
                // Saturating, matching `FloatTrackMixer`'s identical line. Leaving one of a
                // matched pair fixed is the F278/F282 duplication failure, so both move together.
                sampleRate: UInt32(saturating: sampleRate),
                dataByteCount64: dataByteCount
            ),
            to: output
        )
        // The rebuild path: the tracks were already stat'd successfully above to decide what to
        // mix, so the same lookup cannot newly fail here — and if it somehow does, this manifest
        // describes a file this call just built, so a false frame count would be the worst of the
        // three outcomes.
        try writeRecoveryManifestIfNeeded(
            in: directory,
            sampleRate: sampleRate,
            alignment: "zero-aligned-after-interruption",
            truncatedAtSeconds: mix.truncation.map { Double($0.frame) / sampleRate },
            sizeOf: sizeLookup
        )
        rebuildSucceeded = true
        return RecoveredRecording(
            recordingURL: outputURL,
            duration: Double(writtenFrames) / sampleRate,
            source: .rebuiltSourceTracks,
            truncatedAtSeconds: mix.truncation.map { Double($0.frame) / sampleRate },
            expectedDurationSeconds: Double(totalFrames) / sampleRate
        )
    }

    /// Finds an imported recording file (`recording.<ext>`) in a folder that has no live-capture
    /// artifacts, so an imported meeting that fell out of the index can be re-indexed on launch.
    private static func importedRecording(in directory: URL) -> URL? {
        guard let candidate = importedRecordingCandidate(in: directory),
              let values = try? candidate.resourceValues(forKeys: [.fileSizeKey]),
              (values.fileSize ?? 0) > 0 else {
            return nil
        }
        return candidate
    }

    /// Returns the protected imported file even when it is empty or otherwise not recoverable. The
    /// app uses this to create one persistent "Needs attention" entry instead of repeating a
    /// startup warning while still preserving the file for inspection.
    public static func importedRecordingCandidate(in directory: URL) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return nil
        }
        return contents.first { url in
            guard url.deletingPathExtension().lastPathComponent == "recording",
                  !url.pathExtension.isEmpty,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else {
                return false
            }
            return values.isRegularFile == true
        }
    }

    /// Frames in a raw `.f32` track: 0 when absent, a throw when present but unstattable (F280).
    /// How many frames a rebuild of this folder would produce: the longer of the two tracks, which
    /// is what `rebuildFromSourceTracks` mixes to. Zero when neither track has any.
    ///
    /// Exposed for `SourceRebuild`'s precondition (F267), which has to answer "is there anything to
    /// rebuild from" without rebuilding. It takes its own lookup because that question tolerates a
    /// stat failure — a track it cannot describe is one it should not offer — where the rebuild
    /// itself must throw (F280).
    static func sourceTrackFrames(in directory: URL, sizeOf sizeLookup: (URL) -> Int64?) -> Int64 {
        let system = sizeLookup(directory.appendingPathComponent(systemFile))
        let microphone = sizeLookup(directory.appendingPathComponent(microphoneFile))
        let bytesPerFrame = Int64(MemoryLayout<Float>.size)
        return max((system ?? 0) / bytesPerFrame, (microphone ?? 0) / bytesPerFrame)
    }

    private static func frameCount(at url: URL, sizeOf sizeLookup: SizeLookup) throws -> Int64 {
        guard let size = try sizeLookup(url) else { return 0 }
        return size / Int64(MemoryLayout<Float>.size)
    }

    /// The duration of a finalized recording at `url`, or nil when it is not one. Test seam.
    static func finalizedDuration(at url: URL) -> TimeInterval? { wavDuration(at: url) }

    private static func wavDuration(at url: URL) -> TimeInterval? {
        // An RF64 recording (F302) carries its length in `ds64`, which the shared header reader
        // understands. The same rule applies as below: a file shorter than it declares is not a
        // finished recording.
        if let magic = try? FileHandle(forReadingFrom: url).read(upToCount: 4),
           String(data: magic, encoding: .ascii) == "RF64" {
            guard let header = WAVInspection.header(at: url),
                  let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
            else { return nil }
            let frameBytes = UInt64(header.channels) * UInt64(header.bitsPerSample) / 8
            let bytesPerSecond = UInt64(header.sampleRate) * frameBytes
            guard bytesPerSecond > 0, header.declaredDataBytes > 0,
                  UInt64(header.dataOffset) + header.declaredDataBytes <= size else { return nil }
            return Double(header.declaredDataBytes) / Double(bytesPerSecond)
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = (attributes[.size] as? NSNumber)?.uint64Value else {
            return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 44),
              header.count == 44,
              String(data: header[0..<4], encoding: .ascii) == "RIFF",
              String(data: header[8..<12], encoding: .ascii) == "WAVE" else {
            return nil
        }
        let channels = UInt32(littleEndianUInt16(in: header, at: 22))
        let sampleRate = littleEndianUInt32(in: header, at: 24)
        let bitsPerSample = UInt32(littleEndianUInt16(in: header, at: 34))
        let dataByteCount = littleEndianUInt32(in: header, at: 40)
        let bytesPerSecond = sampleRate * channels * bitsPerSample / 8
        let requiredFileSize = UInt64(44) + UInt64(dataByteCount)
        guard bytesPerSecond > 0,
              dataByteCount > 0,
              requiredFileSize <= fileSize else {
            return nil
        }
        return Double(dataByteCount) / Double(bytesPerSecond)
    }

    private static func littleEndianUInt16(in data: Data, at index: Int) -> UInt16 {
        UInt16(data[index]) | (UInt16(data[index + 1]) << 8)
    }

    private static func littleEndianUInt32(in data: Data, at index: Int) -> UInt32 {
        UInt32(data[index])
            | (UInt32(data[index + 1]) << 8)
            | (UInt32(data[index + 2]) << 16)
            | (UInt32(data[index + 3]) << 24)
    }

    private static func writeRecoveryManifestIfNeeded(
        in directory: URL,
        sampleRate: Double,
        alignment: String,
        truncatedAtSeconds: TimeInterval? = nil,
        sizeOf sizeLookup: SizeLookup = InterruptedRecordingRecovery.fileSizeLookup
    ) throws {
        let capturedManifest = directory.appendingPathComponent("source-tracks.json")
        let recoveredManifest = directory.appendingPathComponent("source-tracks.recovered.json")
        guard !FileManager.default.fileExists(atPath: capturedManifest.path),
              !FileManager.default.fileExists(atPath: recoveredManifest.path) else {
            return
        }
        // F282: carry forward any gaps the capture padded. A capture that was padded and THEN
        // interrupted never reached `stop()`, so `source-tracks.json` was never written and the
        // padding survives only in the session sidecar — without this, the inserted silence is
        // invisible in every manifest the folder has, and a consumer would count it as recorded
        // non-speech.
        let session = RecordingSessionSidecar.read(in: directory)
        let paddedGaps = session?.paddedGaps ?? []
        // Mapped once, and used for both the gap list and the label — passing the sidecar's own
        // type to the label function is what caught this; they are different shapes on purpose.
        let manifestGaps = paddedGaps.map { gap -> SourceTrackManifest.PaddedGap in
            // The sidecar records the gap's duration and when capture resumed; the manifest wants
            // where it BEGINS in the recording's own timeline. Derived as
            // (resumedAt - startedAt) - duration, which is the only place both ends are known.
            //
            // Wall clock, not frames: the capture-path manifest gets the true frame offset from
            // `AudioCaptureEngine`, but that offset died with the process here, so this is the best
            // available answer rather than the same answer. It is approximate by however much
            // capture lagged wall clock, which is why it is clamped at zero.
            let resumedAfterStart = session
                .map { gap.resumedAt.timeIntervalSince($0.startedAt) } ?? gap.seconds
            return SourceTrackManifest.PaddedGap(
                startSeconds: max(0, resumedAfterStart - gap.seconds),
                durationSeconds: gap.seconds
            )
        }
        let manifest = SourceTrackManifest.rebuilt(
            sampleRate: sampleRate,
            systemFile: systemFile,
            systemFrameCount: try frameCount(
                at: directory.appendingPathComponent(systemFile),
                sizeOf: sizeLookup
            ),
            microphoneFile: microphoneFile,
            microphoneFrameCount: try frameCount(
                at: directory.appendingPathComponent(microphoneFile),
                sizeOf: sizeLookup
            ),
            paddedGaps: manifestGaps,
            truncatedAtSeconds: truncatedAtSeconds,
            // A lookup into a closed set, NOT string concatenation. `"\(alignment)-with-padding"`
            // reads fine for one dimension and becomes unparseable at two — every reader compares
            // this field by equality, so a value assembled from parts is a value nobody can match.
            // `recoveryAlignment` is a label naming one state; anything needing a history of
            // transformations gets its own field (F282).
            alignment: SourceTrackManifest.alignment(
                forRebuildWith: alignment,
                paddedGaps: manifestGaps
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: recoveredManifest, options: .atomic)
    }
}

private final class RawFloatReader {
    private let handle: FileHandle?

    init(url: URL?) throws {
        handle = try url.map(FileHandle.init(forReadingFrom:))
    }

    deinit {
        try? handle?.close()
    }

    /// A short read zero-pads; a genuine I/O error throws (F256).
    ///
    /// These were the same value before: `try?` collapsed an unreadable block and end-of-file into
    /// zero-filled samples, so a bad block became silence that the caller wrote out and reported as
    /// a successful recovery. The EOF path must keep zero-padding — the two `.f32` files are written
    /// independently from one capture callback, so an abrupt stop leaves them ragged and the shorter
    /// one is padded to the longer. Only the error case is new.
    func read(frameCount: Int) throws -> [Float] {
        var result = [Float](repeating: 0, count: frameCount)
        guard let handle else { return result }
        guard let data = try handle.read(upToCount: frameCount * MemoryLayout<Float>.size),
              !data.isEmpty else {
            return result
        }
        data.withUnsafeBytes { bytes in
            let source = bytes.bindMemory(to: Float.self)
            for index in 0..<min(source.count, result.count) {
                result[index] = source[index]
            }
        }
        return result
    }
}
