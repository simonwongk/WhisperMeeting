import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

/// A 48 kHz mono 16-bit WAV of `seconds` of silence — the real `meeting.wav` layout the segment
/// re-run slices against (F92).
private func writeSilentWav(seconds: Double, to url: URL) throws {
    let sampleRate: UInt32 = 48_000
    let frames = UInt32(seconds * Double(sampleRate))
    let dataBytes = frames * 2
    var wav = WAVWriter.header(sampleRate: sampleRate, dataByteCount: dataBytes)
    wav.append(Data(count: Int(dataBytes)))
    try wav.write(to: url)
}

// F92 — re-transcribing a single segment slices that segment's audio out of meeting.wav, runs the
// engine on the clip, and splices the result back into the transcript — never modifying the recording.
@MainActor
@Test("Per-segment re-run splices the re-transcription in place and never touches the recording (F92)")
func segmentReRunSplicesWithoutTouchingAudio() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SegmentRerun-\(UUID().uuidString)")
    let id = UUID()
    let dir = root.appendingPathComponent("Recordings/\(id.uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let wavURL = dir.appendingPathComponent("meeting.wav")
    try writeSilentWav(seconds: 3, to: wavURL)
    let manifestURL = dir.appendingPathComponent("source-tracks.json")
    try Data("{\"stub\":true}".utf8).write(to: manifestURL)

    let defaults = UserDefaults(suiteName: "F92.\(UUID().uuidString)")!
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    let segments = [seg("first", 0, 1), seg("second wrong", 1, 2), seg("third", 2, 3)]
    model.store.upsert(MeetingRecord(
        id: id, title: "M",
        recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed,
        transcriptText: TranscriptFormatter.timestamped(segments),
        segments: segments
    ))
    let wavBefore = try Data(contentsOf: wavURL)
    let manifestBefore = try Data(contentsOf: manifestURL)

    // The injected engine returns the corrected text with clip-relative timing (start 0).
    model.runTranscriptionEngineOverride = { _, clipURL in
        #expect(FileManager.default.fileExists(atPath: clipURL.path))   // a real clip was written
        return TranscriptionResult(
            id: "x", text: "second right", languageCode: "en",
            audioDuration: 1, confidence: nil, segments: [seg("second right", 0, 1)]
        )
    }

    await model.reTranscribeSegment(id: id, index: 1)

    let updated = model.store.meeting(id: id)
    #expect(updated?.segments.count == 3)                       // spliced in place
    #expect(updated?.segments[1].text == "second right")
    #expect(updated?.segments[1].start == 1.0)                  // re-anchored to the original start
    #expect(updated?.segments[0].text == "first")               // neighbors untouched
    #expect(updated?.segments[2].text == "third")

    // The recording and its manifest are byte-for-byte unchanged.
    #expect(try Data(contentsOf: wavURL) == wavBefore)
    #expect(try Data(contentsOf: manifestURL) == manifestBefore)
}

// F92 (audit fix) — if the re-run returns no timestamped segments (a valid Qwen outcome when alignment
// fails), the original segment's text must be PRESERVED, never replaced with nothing.
@MainActor
@Test("Per-segment re-run with an empty result keeps the original segment (no transcript loss)")
func segmentReRunWithEmptyResultPreservesOriginal() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SegRerunEmpty-\(UUID().uuidString)")
    let id = UUID()
    let dir = root.appendingPathComponent("Recordings/\(id.uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSilentWav(seconds: 3, to: dir.appendingPathComponent("meeting.wav"))

    let defaults = UserDefaults(suiteName: "F92e.\(UUID().uuidString)")!
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    let segments = [seg("first", 0, 1), seg("keep me", 1, 2), seg("third", 2, 3)]
    model.store.upsert(MeetingRecord(
        id: id, title: "M", recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed, transcriptText: TranscriptFormatter.timestamped(segments), segments: segments
    ))
    // The engine returns text but no timestamped segments.
    model.runTranscriptionEngineOverride = { _, _ in
        TranscriptionResult(id: "x", text: "unaligned text", languageCode: "en",
                            audioDuration: 1, confidence: nil, segments: [])
    }

    await model.reTranscribeSegment(id: id, index: 1)

    let updated = model.store.meeting(id: id)
    #expect(updated?.segments.count == 3)
    #expect(updated?.segments[1].text == "keep me")   // preserved, not deleted
}

// F92 (audit fix) — an imported recording that isn't a PCM WAV must not be sliced as raw WAV bytes;
// re-run leaves the transcript untouched and surfaces guidance instead of producing garbage.
@MainActor
@Test("Per-segment re-run refuses a non-WAV recording and leaves the transcript intact")
func segmentReRunRefusesNonWavRecording() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SegRerunNonWav-\(UUID().uuidString)")
    let id = UUID()
    let dir = root.appendingPathComponent("Recordings/\(id.uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // An imported file kept its original container: no RIFF/WAVE header.
    let recURL = dir.appendingPathComponent("meeting.m4a")
    try Data(repeating: 0x41, count: 4_096).write(to: recURL)

    let defaults = UserDefaults(suiteName: "F92n.\(UUID().uuidString)")!
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    let segments = [seg("first", 0, 1), seg("second", 1, 2)]
    model.store.upsert(MeetingRecord(
        id: id, title: "M", recordingPath: "Recordings/\(id.uuidString)/meeting.m4a",
        status: .completed, transcriptText: TranscriptFormatter.timestamped(segments), segments: segments
    ))
    var engineRan = false
    model.runTranscriptionEngineOverride = { _, _ in
        engineRan = true
        return TranscriptionResult(id: "x", text: "junk", languageCode: "en", audioDuration: 1, confidence: nil, segments: [seg("junk", 0, 1)])
    }

    await model.reTranscribeSegment(id: id, index: 1)

    #expect(engineRan == false)                                   // never fed garbage bytes to an engine
    #expect(model.store.meeting(id: id)?.segments[1].text == "second")   // transcript intact
    #expect(model.alertMessage != nil)                            // guidance surfaced
}
