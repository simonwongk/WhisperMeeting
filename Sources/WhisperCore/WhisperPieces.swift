import Foundation

// F533 — a long recording is transcribed by Whisper in bounded pieces.
//
// openai-whisper builds the log-mel spectrogram of the WHOLE input before it decodes a word
// (`whisper/transcribe.py:139` in the pinned 20250625 and on github.com/openai/whisper main,
// 2026-10-08: `mel = log_mel_spectrogram(audio, model.dims.n_mels, padding=N_SAMPLES)`), about
// 3 GB an hour of audio on top of ~6 GB of weights. `--clip_timestamps` does not help: it only
// chooses where the seek loop starts and stops (`:168-176`), AFTER that mel has been computed. So
// the bound has to be on the file Whisper is handed, and each piece is a file of its own.
//
// The user's decision (2026-10-08): recordings over ~45 minutes are transcribed in pieces of
// ~30–45 minutes, cut at quiet moments, with the segment times offset and joined.

/// Where a long recording is cut (F533).
public struct WhisperPiecePolicy: Sendable, Equatable {
    /// A recording longer than this is split, and no piece is ever longer — the hard bound on what
    /// one Whisper process holds in memory. At least one second.
    public let maximumPieceSeconds: Double
    /// How far either side of each cut's target the quietest moment is looked for. Never more than
    /// a quarter of a piece, so every cut makes progress.
    public let quietSearchSeconds: Double

    public init(maximumPieceSeconds: Double, quietSearchSeconds: Double) {
        // Constant first, so NaN falls to the constant (`max(x, y)` is `y >= x ? y : x`).
        let maximum = max(1, maximumPieceSeconds)
        self.maximumPieceSeconds = maximum
        self.quietSearchSeconds = min(maximum / 4, max(0, quietSearchSeconds))
    }

    /// 45 minutes, the bound the user chose, searched ±2 minutes. Pieces are aimed at equal lengths
    /// of at most 43 minutes, so the search can never take one past 45: three hours is five pieces
    /// of about 36 minutes, ninety minutes three of about 30, and a recording just past 45 minutes
    /// two of about 23 — no split of 46 minutes can make both pieces 30. Two minutes either side of
    /// a target is long enough to hold a pause between speakers in any real meeting; the Qwen
    /// helper's ±5 s (below) is for 60-second chunks, not 40-minute ones.
    public static let standard = WhisperPiecePolicy(maximumPieceSeconds: 45 * 60, quietSearchSeconds: 120)
}

/// Plans the pieces of a decoded recording (F533). Pure.
///
/// Mirrors the Qwen helper's splitter — mlx-audio 0.3.1's `split_audio_into_chunks`
/// (`mlx_audio/stt/models/qwen3_asr/qwen3_asr.py:38-126` in the pinned venv), which
/// `Scripts/qwen_transcribe.py` calls — in the two ways that matter: a cut is placed at the
/// lowest-energy 100 ms window (`min_window_ms=100`) within a search window around its target, and
/// the cut is the centre of that window (`argmin + min_window_samples // 2`). It differs in three,
/// deliberately:
///
/// - **A piece is never longer than the bound.** mlx-audio searches ±5 s around `start + chunk`,
///   so a chunk can run 5 s past `chunk_duration`. Here the search window is clipped to
///   `start + maximum`, and with no quiet moment in it the cut is a hard one at the target.
/// - **The targets are balanced.** mlx-audio cuts every chunk at full length and leaves the rest as
///   a tail, which here could be a 2-second piece after two 45-minute ones. The remaining audio is
///   divided into the fewest pieces that leave room for the search window, recomputed after each cut.
/// - **Fixed frames, not a sliding window.** mlx-audio slides its 100 ms window one sample at a time
///   (`np.convolve(…, mode="valid")`, `qwen3_asr.py:99-104`), and `argmin` takes the earliest
///   minimum. Here the energies are of fixed, non-overlapping 100 ms frames (`WhisperAudioEnergy`
///   keeps one number per frame, not one per sample), and a tie goes to the frame nearest the
///   target. A pause scores as silent only where it covers a whole frame, so a pause of 100 to
///   200 ms can straddle two frames and score as neither, where mlx-audio's window would find it.
public enum WhisperPiecePlanner {
    /// openai-whisper's `SAMPLE_RATE` (`whisper/audio.py:13`); the decode is to this rate.
    public static let sampleRate = 16_000
    /// 100 ms at `sampleRate` — mlx-audio's `min_window_ms`.
    public static let frameSamples = 1_600

    /// The sample ranges of the pieces, in order, covering `0..<totalSamples` with no gap or
    /// overlap. One range when the recording is within the bound; none when it is empty.
    ///
    /// `frameEnergies[i]` is the mean square of samples `i * frameSamples ..< (i + 1) * frameSamples`
    /// (`WhisperAudioEnergy`). A missing or short profile is not an error: a target with no frame to
    /// judge it by is cut hard, and the bound still holds.
    public static func pieces(totalSamples: Int, frameEnergies: [Double], policy: WhisperPiecePolicy) -> [Range<Int>] {
        guard totalSamples > 0 else { return [] }
        let maximum = max(1, Int(saturating: policy.maximumPieceSeconds * Double(sampleRate)))
        guard totalSamples > maximum else { return [0..<totalSamples] }
        let search = min(maximum / 4, max(0, Int(saturating: policy.quietSearchSeconds * Double(sampleRate))))
        // The longest a piece can be aimed at and still have its whole search window inside the
        // bound. At least three quarters of the bound, so the loop below always advances.
        let unit = maximum - search

        var pieces: [Range<Int>] = []
        var start = 0
        while totalSamples - start > maximum {
            let remaining = totalSamples - start
            let count = (remaining + unit - 1) / unit      // ≥ 2, since remaining > maximum ≥ unit
            let target = start + remaining / count         // ≤ start + unit, so target + search ≤ start + maximum
            let lower = max(start + 1, target - search)
            let upper = min(start + maximum, target + search, totalSamples - 1)
            let cut = quietestCut(in: lower...max(lower, upper), target: target, frameEnergies: frameEnergies)
            pieces.append(start..<cut)
            start = cut
        }
        pieces.append(start..<totalSamples)
        return pieces
    }

    /// The centre of the quietest frame whose centre lies in `window`; ties go to the centre nearest
    /// `target`, then the earlier. With no such frame, `target` clamped to `window`.
    static func quietestCut(in window: ClosedRange<Int>, target: Int, frameEnergies: [Double]) -> Int {
        let half = frameSamples / 2
        // Frames whose centre `f * frameSamples + half` is inside the window.
        let firstFrame = max(0, (window.lowerBound - half + frameSamples - 1) / frameSamples)
        let lastFrame = min(frameEnergies.count - 1, (window.upperBound - half) / frameSamples)
        var best: (energy: Double, distance: Int, cut: Int)?
        if window.upperBound >= half, firstFrame <= lastFrame {
            for frame in firstFrame...lastFrame {
                let energy = frameEnergies[frame]
                guard !energy.isNaN else { continue }
                let cut = frame * frameSamples + half
                let distance = abs(cut - target)
                if let current = best, (energy, distance) >= (current.energy, current.distance) { continue }
                best = (energy, distance, cut)
            }
        }
        return best?.cut ?? min(window.upperBound, max(window.lowerBound, target))
    }
}

/// Accumulates the per-frame energy of 16-bit little-endian mono PCM as it streams past (F533), so
/// a multi-hour decode is measured in one pass without being held: what it keeps is one number per
/// 100 ms frame, ~108,000 for three hours. Bytes may arrive in chunks of any size, odd ones included.
public struct WhisperAudioEnergy: Sendable {
    public private(set) var sampleCount = 0
    private var energies: [Double] = []
    private var frameSum = 0.0
    private var frameCount = 0
    private var pendingByte: UInt8?

    public init() {}

    public mutating func consume(_ data: Data) {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var index = 0
            if let low = pendingByte, buffer.count > 0 {
                add(low, buffer[0])
                pendingByte = nil
                index = 1
            }
            while index + 1 < buffer.count {
                add(buffer[index], buffer[index + 1])
                index += 2
            }
            if index < buffer.count { pendingByte = buffer[index] }
        }
    }

    private mutating func add(_ low: UInt8, _ high: UInt8) {
        let value = Double(Int16(bitPattern: UInt16(low) | (UInt16(high) << 8))) / 32_768
        frameSum += value * value
        frameCount += 1
        sampleCount += 1
        if frameCount == WhisperPiecePlanner.frameSamples {
            energies.append(frameSum / Double(frameCount))
            frameSum = 0
            frameCount = 0
        }
    }

    /// The mean square of each 100 ms frame, the last one over however many samples it has.
    public func frameEnergies() -> [Double] {
        frameCount > 0 ? energies + [frameSum / Double(frameCount)] : energies
    }
}

/// The file side of splitting (F533): how long a WAV says it is, measuring a decode, and writing a
/// piece. A multi-hour decode is streamed, never loaded: each read is one chunk, read inside its own
/// autorelease pool, so the app holds one chunk of it at a time.
///
/// The pools are what make that true. `FileHandle.read(upToCount:)` returns each chunk in an
/// autoreleased buffer, and nothing drains a pool inside one call. Without them every chunk stayed
/// allocated until the job ended, and the app held the whole decode, about 115 MB per hour of audio,
/// beside every Whisper process (the lane L review's R1).
enum WhisperPieceAudio {
    /// How much is read or copied at a time.
    static let chunkBytes = 1 << 20

    /// Integer PCM, IEEE float, and the extensible wrapper around either: the format tags whose byte
    /// rate is sample rate × channels × bits, which `wavDurationSeconds` divides by.
    static let uncompressedFormatTags: Set<UInt16> = [1, 3, 0xFFFE]

    /// A WAV's duration from its header alone, or nil when the header cannot say: unreadable, or a
    /// format whose bytes per second are not its sample rate × channels × bits (compressed WAV).
    /// Only ever used to decide that a decode is unnecessary, so it errs long: a header that
    /// declares no data (a writer that never finalised) is taken at the file's size.
    static func wavDurationSeconds(at url: URL) -> Double? {
        guard let header = WAVInspection.header(at: url),
              uncompressedFormatTags.contains(header.formatTag),
              header.bytesPerSecond > 0,
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber else {
            return nil
        }
        let fileBytes = size.uint64Value
        let available = fileBytes > UInt64(header.dataOffset) ? fileBytes - UInt64(header.dataOffset) : 0
        let bytes = header.declaredDataBytes == 0 ? available : min(header.declaredDataBytes, available)
        return Double(bytes) / Double(header.bytesPerSecond)
    }

    /// Streams a decoded 16 kHz s16le file through `WhisperAudioEnergy`, one chunk at a time.
    static func measure(_ url: URL) throws -> WhisperAudioEnergy {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var energy = WhisperAudioEnergy()
        while true {
            try Task.checkCancellation()
            let more = try autoreleasepool { () throws -> Bool in
                guard let data = try handle.read(upToCount: chunkBytes), !data.isEmpty else { return false }
                energy.consume(data)
                return true
            }
            guard more else { return energy }
        }
    }

    /// Writes samples `piece` of the decoded `audio` as a 16 kHz mono 16-bit WAV — the format
    /// `load_audio` decodes back to the identical samples, with no resampling.
    static func writePiece(_ piece: Range<Int>, from audio: URL, to url: URL) throws {
        let byteCount = UInt64(piece.count) * 2
        let header = WAVWriter.header(sampleRate: UInt32(WhisperPiecePlanner.sampleRate), dataByteCount64: byteCount)
        guard FileManager.default.createFile(atPath: url.path, contents: header) else {
            throw LocalWhisperError.processFailed("a piece of the recording could not be written to \(url.lastPathComponent).")
        }
        let input = try FileHandle(forReadingFrom: audio)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        try output.seekToEnd()
        try input.seek(toOffset: UInt64(piece.lowerBound) * 2)
        var left = byteCount
        while left > 0 {
            try Task.checkCancellation()
            let want = Int(min(UInt64(chunkBytes), left))
            try autoreleasepool {
                guard let data = try input.read(upToCount: want), !data.isEmpty else {
                    throw LocalWhisperError.processFailed("the decoded recording ended before its last piece did.")
                }
                try output.write(contentsOf: data)
                left -= UInt64(data.count)
            }
        }
    }
}

/// One piece's transcript as openai-whisper wrote it, times relative to the piece (F533).
public struct WhisperPieceTranscript: Sendable, Equatable {
    /// The JSON's `text`, untrimmed.
    public let text: String
    /// The JSON's `language`: the detected code, or the `--language` value exactly as passed.
    public let language: String?
    /// Already trimmed, with empty segments dropped — `LocalWhisperClient`'s own rule.
    public let segments: [TranscriptSegment]

    public init(text: String, language: String?, segments: [TranscriptSegment]) {
        self.text = text
        self.language = language
        self.segments = segments
    }
}

/// Joins piece transcripts into the one result a single pass would have returned (F533). Pure.
///
/// A recording within the bound is one piece at offset 0, and joining one piece IS the one-pass
/// result — `LocalWhisperClient` routes both through here, so there is one rule, not two.
public enum WhisperPieceJoin {
    /// - Each segment's `start`/`end` gains its piece's offset, in seconds (F287's unit).
    /// - Segments stay in piece order, which is time order: pieces are consecutive and disjoint.
    /// - `languageCode` is the FIRST piece's — the one language detection ran on, exactly as one
    ///   pass detects once from the start of the recording; later pieces are pinned to it.
    /// - `text` is the trimmed piece texts, silent ones skipped, joined by the Qwen helper's rule.
    /// - No text at all is `emptyTranscript`, as a silent single pass is.
    public static func join(
        _ pieces: [(offsetSeconds: Double, transcript: WhisperPieceTranscript)], id: String
    ) throws -> TranscriptionResult {
        let text = joinedText(pieces.map { $0.transcript.text.trimmingCharacters(in: .whitespacesAndNewlines) })
        guard !text.isEmpty else { throw LocalWhisperError.emptyTranscript }
        let segments = pieces.flatMap { piece in
            piece.transcript.segments.map { segment in
                var shifted = segment
                shifted.start = segment.start.map { $0 + piece.offsetSeconds }
                shifted.end = segment.end.map { $0 + piece.offsetSeconds }
                return shifted
            }
        }
        return TranscriptionResult(
            id: id,
            text: text,
            languageCode: pieces.first?.transcript.language,
            audioDuration: segments.compactMap(\.end).max(),
            confidence: nil,
            segments: segments
        )
    }

    /// `Scripts/qwen_transcribe.py`'s `joined_text` (F243, F562): empty texts are skipped, and the
    /// boundary gets a space unless the left text's last character AND the right text's first are
    /// both CJK or full-width — a space between two Chinese characters is an error, not neutral
    /// whitespace; between a Chinese and a Latin word it still separates words.
    static func joinedText(_ texts: [String]) -> String {
        var result = ""
        for piece in texts where !piece.isEmpty {
            if let last = result.unicodeScalars.last, let first = piece.unicodeScalars.first,
               !(isCJKOrFullWidth(last) && isCJKOrFullWidth(first)) {
                result += " "
            }
            result += piece
        }
        return result
    }

    /// `_is_cjk_or_fullwidth` in `Scripts/qwen_transcribe.py`, range for range.
    static func isCJKOrFullWidth(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3000...0x303F, 0xFF00...0xFFEF: true
        default: false
        }
    }
}

/// A piece's progress as progress through the whole recording (F533). Pure.
public enum WhisperPieceProgress {
    /// - Transcribing: the piece's fraction becomes `(piece start + fraction × piece length) / total`,
    ///   and its time remaining is scaled by how much audio is left in the whole recording against
    ///   how much is left in this piece — the same rate, applied to the rest. Nil when it cannot be.
    /// - Downloading the model: unchanged; it is not progress through the audio.
    /// - Preparing or loading the model: unchanged for the first piece. For a later one it is
    ///   "transcribing, at the start of this piece", so the bar never goes back to indeterminate
    ///   while the next piece's process loads.
    public static func overall(
        _ progress: LocalTranscriptionProgress, pieceIndex: Int, pieces: [Range<Int>]
    ) -> LocalTranscriptionProgress {
        guard pieces.indices.contains(pieceIndex), let total = pieces.last?.upperBound, total > 0 else {
            return progress
        }
        let piece = pieces[pieceIndex]
        switch progress.phase {
        case .downloadingModel:
            return progress
        case .preparing, .loadingModel:
            guard pieceIndex > 0 else { return progress }
            return LocalTranscriptionProgress(
                phase: .transcribing, fractionCompleted: Double(piece.lowerBound) / Double(total)
            )
        case .transcribing:
            let fraction = min(1, max(0, progress.fractionCompleted ?? 0))
            let done = Double(piece.lowerBound) + fraction * Double(piece.count)
            let leftInPiece = (1 - fraction) * Double(piece.count)
            let leftAfterPiece = Double(total - piece.upperBound)
            let remaining = progress.estimatedSecondsRemaining.flatMap { seconds -> TimeInterval? in
                guard leftInPiece > 0 else { return nil }
                return seconds * ((leftInPiece + leftAfterPiece) / leftInPiece)
            }
            return LocalTranscriptionProgress(
                phase: .transcribing,
                fractionCompleted: done / Double(total),
                estimatedSecondsRemaining: remaining
            )
        }
    }
}
