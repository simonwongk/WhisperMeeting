import AVFoundation
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F795 — the real afconvert encode and AVAudioFile decode Shrink depends on. /usr/bin/afconvert
// ships with macOS, the CI runner included, so this is a normal test, not a gated one. The audio is
// synthesized: the bench clips are generated locally and gitignored, so CI does not have them.

/// A 48 kHz mono WAV of a tone, shaped like a capture's `meeting.wav`.
private func captureLikeWAV(seconds: Double, at url: URL) throws {
    let rate = 48_000
    let samples = (0..<Int(seconds * Double(rate))).map {
        Float(0.3 * sin(2 * Double.pi * 220 * Double($0) / Double(rate)))
    }
    try WAVWriter.wavData(from: samples, sampleRate: rate).write(to: url)
}

private func scratch(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test("A capture-like WAV shrinks to 16 kHz mono AAC whose decoded length matches (F795)")
func shrinkEncodesACaptureLikeWAV() throws {
    let dir = try scratch("ShrinkEnc"); defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appendingPathComponent("meeting.wav")
    try captureLikeWAV(seconds: 3, at: input)
    let out = dir.appendingPathComponent("meeting.m4a")
    let work = dir.appendingPathComponent(".shrink-work.wav")

    try AudioCompressor.compressSpeech(input: input, output: out, workingWAV: work)

    #expect(!FileManager.default.fileExists(atPath: work.path), "the working WAV is removed")
    let file = try AVAudioFile(forReading: out)
    #expect(file.fileFormat.settings[AVFormatIDKey] as? UInt32 == kAudioFormatMPEG4AAC)
    #expect(file.fileFormat.channelCount == 1)
    #expect(file.fileFormat.sampleRate == 16_000)
    let original = try #require(DecodedAudio.declaredDuration(of: input))
    #expect(abs(original - 3) < 0.001)
    #expect(abs(try DecodedAudio.fullyDecodedDuration(of: out) - original) < 0.1)
    // About 4.1 KB a second; a generous band, since the clip is 3 s and the container has overhead.
    let bytes = try #require(try out.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    #expect(bytes < Int(original * 8_000) + 8_000)
}

@Test("Corrupt audio data fails the full decode though its header reads the full length (F795)")
func shrinkFullDecodeRejectsCorruptAudioData() throws {
    // Truncation is not the case to test: the encoder writes `moov` before `mdat`, and a file whose
    // `mdat` is cut short fails to open at all, header read or not. Damaged packets inside an intact
    // container are what only a full decode sees: measured, a 3.11 s file with the second half of its
    // `mdat` zeroed still declares 3.11 s, and `ExtAudioFileRead` throws partway through.
    let dir = try scratch("ShrinkCorrupt"); defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appendingPathComponent("meeting.wav")
    try captureLikeWAV(seconds: 6, at: input)
    let out = dir.appendingPathComponent("meeting.m4a")
    try AudioCompressor.compressSpeech(input: input, output: out, workingWAV: dir.appendingPathComponent(".w.wav"))
    var bytes = [UInt8](try Data(contentsOf: out))
    var index = 0, mdat: Range<Int>?
    while index + 8 <= bytes.count {
        let size = Int(UInt32(bytes[index]) << 24 | UInt32(bytes[index + 1]) << 16
            | UInt32(bytes[index + 2]) << 8 | UInt32(bytes[index + 3]))
        if String(decoding: bytes[index + 4..<index + 8], as: UTF8.self) == "mdat" {
            mdat = (index + 8)..<min(bytes.count, index + size)
        }
        guard size >= 8 else { break }
        index += size
    }
    let data = try #require(mdat)
    for k in (data.lowerBound + data.count / 2)..<data.upperBound { bytes[k] = 0 }
    try Data(bytes).write(to: out)

    #expect(abs((DecodedAudio.declaredDuration(of: out) ?? 0) - 6) < 0.1, "the header still says 6 s")
    let decoded = try? DecodedAudio.fullyDecodedDuration(of: out)
    #expect(decoded == nil || abs(decoded! - 6) > 0.5, "decoded \(String(describing: decoded))")
}

@Test("Storage counts every file in the folder, nested ones too, by size on disk (F795)")
func storageMeterCountsTheWholeFolder() throws {
    let dir = try scratch("Meter"); defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try Data(count: 1_000_000).write(to: dir.appendingPathComponent("meeting.wav"))
    try Data(count: 10).write(to: dir.appendingPathComponent("sub/extra.bin"))
    let before = MeetingStorageMeter.entries(in: dir)
    #expect(Set(before.map(\.name)) == ["meeting.wav", "sub/extra.bin"])
    #expect(MeetingStoragePlan.totalBytes(before) >= 1_000_010)
    // Re-measured, not cached: Foundation caches resource values per URL instance (F698).
    try Data(count: 2_000_000).write(to: dir.appendingPathComponent("meeting.wav"))
    #expect(MeetingStoragePlan.totalBytes(MeetingStorageMeter.entries(in: dir)) >= 2_000_010)
}
