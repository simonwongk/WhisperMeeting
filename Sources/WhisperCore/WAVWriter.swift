import Foundation

/// Builds 16-bit PCM mono WAV bytes. Shared by the meeting mixer and quick-dictation capture so
/// there is exactly one WAV path in the codebase.
public enum WAVWriter {
    /// The canonical 44-byte RIFF/WAVE header for 16-bit mono PCM at `sampleRate`.
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
        var data = header(sampleRate: UInt32(sampleRate), dataByteCount: UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
