import Foundation
import Testing
@testable import WhisperCore

// F224 — `WAVInspection.header` read the data-chunk size from a fixed offset (40), which is only
// correct for a canonical 44-byte header. macOS's own `afconvert` — the converter
// `AudioTranscoder.transcodeToWAV` runs before speaker analysis — inserts a 4 KB `FLLR` padding
// chunk between `fmt ` and `data`, so offset 40 lands on the FILLER's size (4044) and the audio is
// measured as 0.13 seconds regardless of length. Found by running the real diarization models over
// a real converted file: every turn then "exceeds" the recording and a whole valid analysis is
// thrown away.

/// A WAV whose `data` chunk is preceded by an `FLLR` filler chunk, exactly as `afconvert` writes.
private func fillerPaddedWAV(sampleRate: UInt32, channels: UInt16, dataBytes: UInt32, fillerBytes: UInt32) -> Data {
    var data = Data()
    func append32(_ v: UInt32) { data.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
    func append16(_ v: UInt16) { data.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
    data.append(contentsOf: Array("RIFF".utf8))
    append32(36 + fillerBytes + 8 + dataBytes)
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8))
    append32(16)
    append16(1)                                   // PCM
    append16(channels)
    append32(sampleRate)
    append32(sampleRate * UInt32(channels) * 2)   // byte rate
    append16(channels * 2)                        // block align
    append16(16)                                  // bits per sample
    data.append(contentsOf: Array("FLLR".utf8))
    append32(fillerBytes)
    data.append(Data(count: Int(fillerBytes)))
    data.append(contentsOf: Array("data".utf8))
    append32(dataBytes)
    data.append(Data(count: Int(dataBytes)))
    return data
}

@Test("A WAV with an afconvert filler chunk still reports its real audio length (F224)")
func wavInspectionSkipsFillerChunksBeforeData() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WAVInspectionChunk-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("converted.wav")
    // 30.49 s at 16 kHz mono 16-bit, the shape afconvert produced from a 30-second fixture.
    try fillerPaddedWAV(sampleRate: 16_000, channels: 1, dataBytes: 975_730, fillerBytes: 4_044)
        .write(to: url)

    let header = try #require(WAVInspection.header(at: url))

    #expect(header.sampleRate == 16_000)
    #expect(header.channels == 1)
    #expect(header.bitsPerSample == 16)
    #expect(header.declaredDataBytes == 975_730)   // not the filler's 4044
    #expect(header.dataOffset == 4_096)            // where the audio actually starts
}

@Test("A canonical 44-byte WAV header is unchanged by chunk walking (F224)")
func wavInspectionStillReadsACanonicalHeader() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WAVInspectionCanonical-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("recorded.wav")
    var wav = WAVWriter.header(sampleRate: 48_000, dataByteCount: 96_000)
    wav.append(Data(count: 96_000))
    try wav.write(to: url)

    let header = try #require(WAVInspection.header(at: url))

    #expect(header.sampleRate == 48_000)
    #expect(header.channels == 1)
    #expect(header.declaredDataBytes == 96_000)
    #expect(header.dataOffset == 44)
}

@Test("A file that is not RIFF/WAVE, or has no data chunk, still reads as unreadable (F224)")
func wavInspectionRejectsNonWAVAndHeaderlessFiles() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WAVInspectionBad-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let notRIFF = directory.appendingPathComponent("notes.txt")
    try Data(repeating: 0x41, count: 200).write(to: notRIFF)
    #expect(WAVInspection.header(at: notRIFF) == nil)

    // RIFF/WAVE with a fmt chunk but no data chunk at all: there is no audio to measure, and
    // guessing one is how a truncated file gets reported as healthy.
    var headerless = Data()
    headerless.append(contentsOf: Array("RIFF".utf8))
    headerless.append(contentsOf: withUnsafeBytes(of: UInt32(28).littleEndian) { Array($0) })
    headerless.append(contentsOf: Array("WAVE".utf8))
    headerless.append(contentsOf: Array("fmt ".utf8))
    headerless.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
    headerless.append(Data(count: 16))
    let noData = directory.appendingPathComponent("nodata.wav")
    try headerless.write(to: noData)
    #expect(WAVInspection.header(at: noData) == nil)
}
