import Foundation
import Testing
@testable import WhisperCore

/// Builds a 44-byte 16-bit-PCM WAV header declaring `dataBytes` of audio.
private func wavHeader(sampleRate: UInt32, channels: UInt16, bitsPerSample: UInt16, dataBytes: UInt32) -> Data {
    var data = Data()
    func append32(_ v: UInt32) { data.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
    func append16(_ v: UInt16) { data.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
    data.append(contentsOf: Array("RIFF".utf8))
    append32(36 + dataBytes)
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8))
    append32(16)
    append16(1) // PCM
    append16(channels)
    append32(sampleRate)
    append32(sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8) // byte rate
    append16(channels * bitsPerSample / 8) // block align
    append16(bitsPerSample)
    data.append(contentsOf: Array("data".utf8))
    append32(dataBytes)
    return data
}

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("MeetingIntegrityCheckerTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// F66 — the meeting-library integrity checker.
@Test("Integrity checker flags missing, truncated, and frame-mismatched audio; healthy returns none")
func meetingIntegrityChecker() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    // 1 second at 16 kHz mono 16-bit = 32000 data bytes.
    let dataBytes: UInt32 = 32_000

    // Healthy: header declares exactly what's present, source track has the expected frames.
    let healthyWav = dir.appendingPathComponent("healthy.wav")
    try (wavHeader(sampleRate: 16_000, channels: 1, bitsPerSample: 16, dataBytes: dataBytes)
        + Data(count: Int(dataBytes))).write(to: healthyWav)
    let healthyTrack = dir.appendingPathComponent("healthy.f32")
    try Data(count: 16_000 * MemoryLayout<Float>.size).write(to: healthyTrack) // 16000 frames
    let healthy = MeetingIntegrityChecker.check(MeetingIntegrityDescriptor(
        recordingURL: healthyWav,
        sourceTracks: [.init(name: "microphone", url: healthyTrack, expectedFrameCount: 16_000)],
        indexDurationSeconds: 1.0
    ))
    #expect(healthy.isEmpty)

    // (a) WAV header declares more data than is present.
    let truncatedWav = dir.appendingPathComponent("truncated.wav")
    try (wavHeader(sampleRate: 16_000, channels: 1, bitsPerSample: 16, dataBytes: dataBytes)
        + Data(count: 100)).write(to: truncatedWav) // only 100 of 32000 data bytes
    let truncated = MeetingIntegrityChecker.check(MeetingIntegrityDescriptor(
        recordingURL: truncatedWav, sourceTracks: [], indexDurationSeconds: nil
    ))
    #expect(truncated.contains { if case .wavTruncated = $0 { return true }; return false })

    // (b) A .f32 shorter than its manifest frameCount.
    let shortTrack = dir.appendingPathComponent("short.f32")
    try Data(count: 100 * MemoryLayout<Float>.size).write(to: shortTrack) // 100 frames
    let mismatch = MeetingIntegrityChecker.check(MeetingIntegrityDescriptor(
        recordingURL: healthyWav,
        sourceTracks: [.init(name: "system", url: shortTrack, expectedFrameCount: 16_000)],
        indexDurationSeconds: 1.0
    ))
    #expect(mismatch.contains { if case .sourceTrackFrameMismatch = $0 { return true }; return false })

    // (c) Missing meeting.wav.
    let missing = MeetingIntegrityChecker.check(MeetingIntegrityDescriptor(
        recordingURL: dir.appendingPathComponent("nope.wav"), sourceTracks: [], indexDurationSeconds: nil
    ))
    #expect(missing == [.recordingMissing])
}
