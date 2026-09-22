import Foundation

/// Builds 16-bit PCM mono WAV bytes for every path that writes audio: the meeting mixer
/// (`FloatTrackMixer`), quick-dictation capture, the diarization smoke test, and the
/// interrupted-recording rebuild.
///
/// That list is the point. The comment here used to assert "exactly one WAV path in the codebase"
/// while `InterruptedRecordingRecovery` carried its own byte-for-byte copy — an assertion is not a
/// constraint. `WAVHeaderSingleSourceTests` now pins the bytes a real rebuild produces against
/// `header`, so a second implementation fails a test instead of quietly aging.
public enum WAVWriter {
    /// The canonical 44-byte RIFF/WAVE header for 16-bit mono PCM at `sampleRate`.
    ///
    /// `&+` / `&*` rather than `+` / `*`: past `UInt32`'s range these fields are wrong either way
    /// (that is **F150**), but wrapping cannot crash the app while it finalizes a recording, and
    /// trapping can. Losing a meeting to an overflow trap is strictly worse than writing a header
    /// whose size field a player will disagree with.
    public static func header(sampleRate: UInt32, dataByteCount: UInt32) -> Data {
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func le<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        ascii("RIFF"); le(36 &+ dataByteCount); ascii("WAVE")
        ascii("fmt "); le(UInt32(16)); le(UInt16(1)); le(UInt16(1))
        le(sampleRate); le(sampleRate &* 2); le(UInt16(2)); le(UInt16(16))
        ascii("data"); le(dataByteCount)
        return data
    }

    /// The most PCM a classic header can describe: the RIFF size field holds `36 + data` (F302).
    public static let classicDataLimit = UInt64(UInt32.max) - 36

    /// 44 for a classic header, 80 for RF64. A streaming writer reserves this many bytes before
    /// the audio and writes the header over them last, so it must know which it will need first.
    public static func headerLength(
        dataByteCount: UInt64, classicDataLimit: UInt64 = WAVWriter.classicDataLimit
    ) -> Int {
        dataByteCount > classicDataLimit ? 80 : 44
    }

    /// The header for `dataByteCount64` bytes of 16-bit mono PCM: the classic one whenever it can
    /// describe them, RF64 (EBU Tech 3306) when it cannot (F302).
    ///
    /// RF64 is RIFF/WAVE with the two 32-bit size fields set to `0xFFFFFFFF` and the real sizes
    /// carried as 64-bit values in a `ds64` chunk placed first. Core Audio and ffmpeg both read
    /// it. It is written only past the limit so that every ordinary recording stays byte-identical
    /// to what every earlier version wrote. `classicDataLimit` is a parameter so a test can cross
    /// the boundary without writing 4 GiB.
    ///
    /// `forceRF64` is for a writer that **reserved** 80 bytes before it knew how much it would
    /// write: the recovery rebuild reserves from the tracks' declared length and writes from what it
    /// actually mixed, which is less when a track dies partway (F336). The header must fill the
    /// reserve exactly, or the difference is zero bytes sitting inside the declared `data` range.
    public static func header(
        sampleRate: UInt32,
        dataByteCount64: UInt64,
        classicDataLimit: UInt64 = WAVWriter.classicDataLimit,
        forceRF64: Bool = false
    ) -> Data {
        guard forceRF64 || dataByteCount64 > classicDataLimit else {
            return header(sampleRate: sampleRate, dataByteCount: UInt32(clamping: dataByteCount64))
        }
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func le<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        ascii("RF64"); le(UInt32.max); ascii("WAVE")
        // riffSize (everything after the first 8 bytes), dataSize, sampleCount, table length.
        ascii("ds64"); le(UInt32(28)); le(72 &+ dataByteCount64); le(dataByteCount64)
        le(dataByteCount64 / 2); le(UInt32(0))
        ascii("fmt "); le(UInt32(16)); le(UInt16(1)); le(UInt16(1))
        le(sampleRate); le(sampleRate &* 2); le(UInt16(2)); le(UInt16(16))
        ascii("data"); le(UInt32.max)
        return data
    }

    /// Little-endian Int16 samples, clamped to [-1, 1].
    public static func pcm16Data(from samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            var value = Int16(clampedAudioSample: sample).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// A complete WAV file (header + PCM payload) for the given float samples.
    public static func wavData(from samples: [Float], sampleRate: Int) -> Data {
        let pcm = pcm16Data(from: samples)
        // `UInt32(Int)` traps above `UInt32.max`. Every caller passes 16 kHz or 48 kHz, so this
        // is a guard against a future one rather than a live defect — but it is one line, and the
        // consequence is a crash while writing audio.
        var data = header(
            sampleRate: UInt32(saturating: Double(sampleRate)),
            dataByteCount: UInt32(clamping: pcm.count)
        )
        data.append(pcm)
        return data
    }
}
