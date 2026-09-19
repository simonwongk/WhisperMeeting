import AVFoundation
import Foundation
import Testing
@testable import WhisperCore

// F302 — past 4 GiB of PCM (~12.4 h at 48 kHz) the classic WAV size field overflows, so the header
// understated the audio. Decided 2026-09-18 under the user's delegation: RF64 (EBU Tech 3306), the
// 64-bit WAV that Core Audio and ffmpeg both read, written ONLY when the audio needs it — so every
// ordinary recording keeps the byte-identical 44-byte header. Segmenting was rejected: it changes
// what a recording is for every reader, to serve a case RF64 serves without anyone noticing.

@Test("An ordinary recording keeps the classic 44-byte header, byte for byte (F302)")
func ordinaryRecordingsKeepTheClassicHeader() {
    let classic = WAVWriter.header(sampleRate: 48_000, dataByteCount: 96_000)
    #expect(WAVWriter.header(sampleRate: 48_000, dataByteCount64: 96_000) == classic)
    #expect(WAVWriter.headerLength(dataByteCount: 96_000) == 44)
    #expect(WAVWriter.headerLength(dataByteCount: WAVWriter.classicDataLimit) == 44)
}

@Test("Past the classic limit the header is RF64 and declares the real length (F302)")
func longRecordingsGetAnRF64Header() throws {
    // One byte over, not a comfortable million: the boundary is where an off-by-one lives (F344).
    #expect(WAVWriter.headerLength(dataByteCount: WAVWriter.classicDataLimit + 1) == 80)
    #expect(WAVWriter.header(sampleRate: 48_000, dataByteCount64: WAVWriter.classicDataLimit + 1).count == 80)

    let bytes = UInt64(UInt32.max) + 1_000_000
    #expect(WAVWriter.headerLength(dataByteCount: bytes) == 80)
    let header = WAVWriter.header(sampleRate: 48_000, dataByteCount64: bytes)
    #expect(header.count == 80)
    #expect(String(data: header[0..<4], encoding: .ascii) == "RF64")
    #expect(String(data: header[12..<16], encoding: .ascii) == "ds64")
    func le64(_ range: Range<Int>) -> UInt64 {
        var value: UInt64 = 0
        for (offset, byte) in header[range].enumerated() { value |= UInt64(byte) << UInt64(8 * offset) }
        return value
    }
    #expect(le64(20..<28) == 72 + bytes, "riffSize: everything after the first 8 bytes")
    #expect(le64(28..<36) == bytes)
    #expect(le64(36..<44) == bytes / 2, "sampleCount: 16-bit mono, so two bytes a sample")
}

@Test("The integrity checker finds nothing wrong with an RF64 recording (F344)")
func integrityCheckerAcceptsAnRF64Recording() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rf64-check-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("meeting.wav")
    var data = WAVWriter.header(sampleRate: 48_000, dataByteCount64: 9_600, classicDataLimit: 1_000)
    data.append(Data(repeating: 0, count: 9_600))
    try data.write(to: url)

    let header = try #require(WAVInspection.header(at: url))
    #expect(header.declaredDataBytes == 9_600)
    #expect(header.dataOffset == 80)
    #expect(header.sampleRate == 48_000)
    #expect(header.bitsPerSample == 16)
    #expect(header.channels == 1)

    // The sweep itself, which is what the library actually runs over a recovered recording.
    let findings = MeetingIntegrityChecker.check(MeetingIntegrityDescriptor(
        recordingURL: url, sourceTracks: [], indexDurationSeconds: 0.1
    ))
    #expect(findings.isEmpty, "an RF64 recording is a whole recording, not a damaged one")

    // And the same file cut short is still caught, so the acceptance above is not blanket.
    try data.prefix(80 + 4_000).write(to: url)
    let truncated = MeetingIntegrityChecker.check(MeetingIntegrityDescriptor(
        recordingURL: url, sourceTracks: [], indexDurationSeconds: 0.1
    ))
    #expect(truncated.contains { if case .wavTruncated = $0 { return true } else { return false } })
}

private func writeFloats(_ values: [Float], to url: URL) throws {
    try values.withUnsafeBytes { try Data($0).write(to: url) }
}

@Test("A mix that crosses the boundary is a file whose declared length matches its audio (F302)")
func mixPastTheBoundaryDeclaresItsRealLength() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rf64-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let system = root.appendingPathComponent("system-audio.f32")
    let microphone = root.appendingPathComponent("microphone-audio.f32")
    let output = root.appendingPathComponent("meeting.wav")
    let frames = 4_800
    try writeFloats([Float](repeating: 0.25, count: frames), to: system)
    try writeFloats([Float](repeating: 0, count: frames), to: microphone)

    // The boundary is lowered rather than 4 GiB written: the branch is the same, the disk is not.
    let duration = try FloatTrackMixer.mix(
        system: FloatTrack(url: system, firstPresentationTime: 0, frameCount: Int64(frames)),
        microphone: FloatTrack(url: microphone, firstPresentationTime: 0, frameCount: Int64(frames)),
        sampleRate: 48_000, outputURL: output, classicDataLimit: 1_000
    )

    #expect(duration == 0.1)
    let header = try #require(WAVInspection.header(at: output))
    #expect(header.declaredDataBytes == UInt64(frames * 2))
    #expect(header.dataOffset == 80)
    let size = try #require(try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)
    #expect(size.uint64Value == 80 + UInt64(frames * 2))
    // And a reader that is not ours follows the header to the end of the recording.
    let file = try AVAudioFile(forReading: output)
    #expect(file.length == AVAudioFramePosition(frames))
}

@Test("The interrupted-recording scan recognises an RF64 recording as finalized (F302)")
func recoveryRecognisesAnRF64Recording() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rf64-dur-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("meeting.wav")
    var data = WAVWriter.header(sampleRate: 48_000, dataByteCount64: 9_600, classicDataLimit: 1_000)
    data.append(Data(repeating: 0, count: 9_600))
    try data.write(to: url)
    #expect(InterruptedRecordingRecovery.finalizedDuration(at: url) == 0.1)
    // Truncated: the header promises more than the file holds, so it is not a finished recording.
    try data.prefix(80 + 4_000).write(to: url)
    #expect(InterruptedRecordingRecovery.finalizedDuration(at: url) == nil)
}
