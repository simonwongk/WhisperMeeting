import Foundation
import Testing
@testable import WhisperCore

// F435 — two readers of a WAV header did arithmetic that traps. Launch recovery's `wavDuration`
// read channels, sample rate, bit depth and data size at the canonical offsets 22/24/34/40 and
// multiplied them as `UInt32`; the integrity sweep multiplied the same three fields as `UInt32` and
// added the declared size to the data offset after clamping it to `Int64.max`. Each field is in
// range for its own type and the product or sum is not, so one bad file on disk took the app down
// at every launch — `finalizedRecording(in:)` runs from startup recovery and from `MeetingStore`'s
// empty-index check, and `MeetingIntegrityChecker.check` from the launch integrity sweep.
//
// Every test here asserts the value the reader RETURNS, not merely that nothing trapped: a guard
// that stops the trap by saturating can still hand back a number that reads wrong (AGENTS.md).

private func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
private func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
private func le64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

private func chunk(_ identifier: String, _ body: Data) -> Data {
    var data = Data(identifier.utf8)
    data.append(le32(UInt32(body.count)))
    data.append(body)
    if body.count % 2 == 1 { data.append(0) }   // RIFF word alignment
    return data
}

private func fmtBody(channels: UInt16, sampleRate: UInt32, bitsPerSample: UInt16) -> Data {
    var body = le16(1)                                               // PCM
    body.append(le16(channels))
    body.append(le32(sampleRate))
    body.append(le32(sampleRate &* UInt32(channels) &* UInt32(bitsPerSample) / 8))   // byte rate
    body.append(le16(channels &* bitsPerSample / 8))                 // block align
    body.append(le16(bitsPerSample))
    return body
}

/// A RIFF/WAVE file made of `chunks`, in order, with a correct RIFF size.
private func riffWAV(_ chunks: [Data]) -> Data {
    let payload = chunks.reduce(Data("WAVE".utf8), +)
    var file = Data("RIFF".utf8)
    file.append(le32(UInt32(payload.count)))
    file.append(payload)
    return file
}

/// A Broadcast WAV as a field recorder writes it: `bext` FIRST, so the bytes at the canonical
/// offsets 22/24/34/40 are the description text, not the format.
private func broadcastWAV(sampleRate: UInt32, dataBytes: Int) -> Data {
    var bext = Data("sSPEED=023.976-ND\r\nsTAKE=001\r\nsUBITS=$00000000\r\n".utf8)
    bext.append(Data(count: 602 - bext.count))   // EBU Tech 3285 v1's fixed-size body
    return riffWAV([
        chunk("bext", bext),
        chunk("fmt ", fmtBody(channels: 1, sampleRate: sampleRate, bitsPerSample: 16)),
        chunk("data", Data(count: dataBytes)),
    ])
}

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("WAVHeaderArithmetic-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

@Test("Launch recovery reads a bext-first Broadcast WAV import by walking its chunks (F435)")
func recoveryReadsABroadcastWAVImport() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    // Two seconds at 48 kHz mono 16-bit. Read at the canonical offsets this is 17,744 channels at
    // 809,321,541 Hz — the product traps in `UInt32` long before the duration is computed.
    try broadcastWAV(sampleRate: 48_000, dataBytes: 192_000)
        .write(to: folder.appendingPathComponent("recording.wav"))

    let recovered = try #require(InterruptedRecordingRecovery.finalizedRecording(in: folder))

    #expect(recovered.source == .importedRecording)
    #expect(recovered.duration == 2.0)
}

@Test("Launch recovery reads an ffmpeg-shaped WAV (LIST before data) at its real length (F435)")
func recoveryReadsAWAVWithAListChunkBeforeData() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    // ffmpeg's WAV muxer writes its encoder tag as LIST/INFO between `fmt ` and `data`, so offset
    // 40 lands on the LIST size (26) and three seconds of audio read as under a millisecond.
    var info = Data("INFO".utf8)
    info.append(chunk("ISFT", Data("Lavf61.7.100\0".utf8)))
    try riffWAV([
        chunk("fmt ", fmtBody(channels: 1, sampleRate: 16_000, bitsPerSample: 16)),
        chunk("LIST", info),
        chunk("data", Data(count: 96_000)),
    ]).write(to: folder.appendingPathComponent("recording.wav"))

    let recovered = try #require(InterruptedRecordingRecovery.finalizedRecording(in: folder))

    #expect(recovered.duration == 3.0)
}

@Test("A 65535-channel fmt chunk no longer traps recovery, and its duration reads correctly (F435)")
func recoverySurvivesAnOverflowingFormat() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    // 48,000 × 65,535 × 16 is past `UInt32.max`. The header is nonsense, but it is the user's file
    // and it is on disk at every launch.
    try riffWAV([
        chunk("fmt ", fmtBody(channels: 0xFFFF, sampleRate: 48_000, bitsPerSample: 16)),
        chunk("data", Data(count: 1_000)),
    ]).write(to: folder.appendingPathComponent("meeting.wav"))

    let recovered = try #require(InterruptedRecordingRecovery.finalizedRecording(in: folder))

    // 48,000 frames/s × (65,535 × 16 / 8) bytes/frame = 6,291,360,000 bytes/s.
    #expect(recovered.source == .existingCapture)
    #expect(recovered.duration == 1_000.0 / 6_291_360_000.0)
}

@Test("An RF64 file whose ds64 size is still the all-ones placeholder is unfinished, not a trap (F435)")
func recoveryTreatsAnAllOnesRF64SizeAsUnfinished() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("meeting.wav")
    try allOnesRF64(dataBytes: 4_800).write(to: url)

    // `dataOffset + declared` overflowed `UInt64` here. The file holds 4,800 bytes and declares
    // 2^64 − 1, so it is not a finished recording, which is what nil means.
    #expect(InterruptedRecordingRecovery.finalizedDuration(at: url) == nil)
}

/// An RF64 file as a streaming writer leaves it when it could not seek back: every size field,
/// including ds64's 64-bit data size, still the all-ones placeholder.
private func allOnesRF64(dataBytes: Int) -> Data {
    var ds64 = le64(.max)          // riffSize
    ds64.append(le64(.max))        // dataSize
    ds64.append(le64(.max))        // sampleCount
    ds64.append(le32(0))           // table length
    let payload = [
        chunk("ds64", ds64),
        chunk("fmt ", fmtBody(channels: 1, sampleRate: 48_000, bitsPerSample: 16)),
        Data("data".utf8) + le32(.max) + Data(count: dataBytes),
    ].reduce(Data("WAVE".utf8), +)
    return Data("RF64".utf8) + le32(.max) + payload
}

@Test("The integrity sweep reports an all-ones RF64 size as truncated, saturated, without trapping (F435)")
func integritySweepReportsAnAllOnesRF64SizeAsTruncated() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("meeting.wav")
    let file = allOnesRF64(dataBytes: 4_800)
    try file.write(to: url)

    let findings = MeetingIntegrityChecker.check(MeetingIntegrityDescriptor(
        recordingURL: url, sourceTracks: [], indexDurationSeconds: nil
    ))

    // Clamping the declared size to Int64.max and then adding the 80-byte offset was the trap. The
    // report saturates at Int64.max — the most a file can declare — rather than a wrapped negative.
    #expect(findings == [.wavTruncated(declaredBytes: .max, actualBytes: Int64(file.count))])
}

@Test("The integrity sweep measures an overflowing sample rate in 64 bits and reads it correctly (F435)")
func integritySweepSurvivesAnOverflowingSampleRate() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("meeting.wav")
    // 2^28 Hz × 1 channel × 16 bits = 2^32: one past `UInt32.max`.
    try riffWAV([
        chunk("fmt ", fmtBody(channels: 1, sampleRate: 0x1000_0000, bitsPerSample: 16)),
        chunk("data", Data(count: 64_000)),
    ]).write(to: url)

    let findings = MeetingIntegrityChecker.check(MeetingIntegrityDescriptor(
        recordingURL: url, sourceTracks: [], indexDurationSeconds: 2.0
    ))

    // 64,000 bytes at 2^28 frames/s × 2 bytes/frame.
    #expect(findings == [.durationInconsistent(headerSeconds: 64_000.0 / 536_870_912.0, indexSeconds: 2.0)])
}

@Test("The integrity sweep still passes a healthy Broadcast WAV import (F435)")
func integritySweepPassesAHealthyBroadcastWAV() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("recording.wav")
    try broadcastWAV(sampleRate: 48_000, dataBytes: 192_000).write(to: url)

    let findings = MeetingIntegrityChecker.check(MeetingIntegrityDescriptor(
        recordingURL: url, sourceTracks: [], indexDurationSeconds: 2.0
    ))

    // The control for the two above: a correct header of the same shape is not flagged at all.
    #expect(findings.isEmpty)
}
