import Foundation
import Testing
@testable import WhisperCore

// F118 — Qwen's mlx-audio (miniaudio) can't decode containers like .mp4/.mov/.aiff/.caf. Decode-first:
// transcode anything it can't natively read into a 16 kHz mono WAV via afconvert before handing it to
// the engine. This covers the native-format gate and the transcoder's output format.

private func makeWav(sampleRate: UInt32, channels: UInt16, frames: UInt32, at url: URL) throws {
    let bits: UInt16 = 16
    let dataBytes = frames * UInt32(channels) * UInt32(bits) / 8
    var data = Data()
    func a32(_ v: UInt32) { data.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
    func a16(_ v: UInt16) { data.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
    data.append(contentsOf: Array("RIFF".utf8)); a32(36 + dataBytes); data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); a32(16); a16(1); a16(channels); a32(sampleRate)
    a32(sampleRate * UInt32(channels) * UInt32(bits) / 8); a16(channels * bits / 8); a16(bits)
    data.append(contentsOf: Array("data".utf8)); a32(dataBytes)
    data.append(Data(count: Int(dataBytes))) // silence
    try data.write(to: url)
}

/// Read channels + sample rate from a WAV's `fmt ` chunk (afconvert may pad before it).
private func wavFormat(_ data: Data) -> (channels: UInt16, sampleRate: UInt32)? {
    let tag = Array("fmt ".utf8)
    guard data.count >= 44 else { return nil }
    for i in 0..<(data.count - 16) where Array(data[i..<i + 4]) == tag {
        let ch = UInt16(data[i + 10]) | (UInt16(data[i + 11]) << 8)
        let sr = UInt32(data[i + 12]) | (UInt32(data[i + 13]) << 8)
            | (UInt32(data[i + 14]) << 16) | (UInt32(data[i + 15]) << 24)
        return (ch, sr)
    }
    return nil
}

@Test("AudioTranscoder flags non-native containers and produces a 16 kHz mono WAV (F118)")
func audioTranscoderDecodesToWav() throws {
    #expect(AudioTranscoder.needsTranscoding(URL(fileURLWithPath: "/x/clip.mp4")))
    #expect(AudioTranscoder.needsTranscoding(URL(fileURLWithPath: "/x/clip.aiff")))
    #expect(AudioTranscoder.needsTranscoding(URL(fileURLWithPath: "/x/clip.caf")))
    #expect(!AudioTranscoder.needsTranscoding(URL(fileURLWithPath: "/x/clip.wav")))
    // .m4a/.aac now route through decode-first (afconvert) too, so Qwen doesn't depend on ffmpeg (F145).
    #expect(AudioTranscoder.needsTranscoding(URL(fileURLWithPath: "/x/clip.m4a")))
    #expect(AudioTranscoder.needsTranscoding(URL(fileURLWithPath: "/x/clip.aac")))
    #expect(!AudioTranscoder.needsTranscoding(URL(fileURLWithPath: "/x/clip.mp3")))

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AudioTranscoderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let src = dir.appendingPathComponent("src.wav")
    try makeWav(sampleRate: 48_000, channels: 2, frames: 48_000, at: src)
    // Re-wrap as a non-native container (.aiff, which mlx-audio's miniaudio cannot read) so the
    // transcode exercises a real decode, not just a WAV re-encode.
    let aiff = dir.appendingPathComponent("src.aiff")
    let convert = Process()
    convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
    convert.arguments = ["-f", "AIFF", "-d", "BEI16@48000", src.path, aiff.path]
    try convert.run(); convert.waitUntilExit()
    #expect(convert.terminationStatus == 0)

    let out = dir.appendingPathComponent("out.wav")
    try AudioTranscoder.transcodeToWAV(input: aiff, output: out)

    let format = try wavFormat(Data(contentsOf: out))
    #expect(format?.channels == 1)
    #expect(format?.sampleRate == 16_000)
}
