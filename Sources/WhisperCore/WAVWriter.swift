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

    /// Little-endian Int16 samples, clamped to [-1, 1].
    public static func pcm16Data(from samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            var value = Int16(clamped * Float(Int16.max)).littleEndian
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
