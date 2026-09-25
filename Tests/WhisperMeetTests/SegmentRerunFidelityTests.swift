import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F471 — "Re-transcribe this segment" (F92) assumed more than it checked, three ways, each ending
// with the wrong text silently in the user's transcript:
//
// 1. It sliced any RIFF/WAVE as 44 bytes of header and 16-bit mono PCM. An imported file is kept
//    verbatim, so a WAV with a LIST chunk was sliced from the wrong offset, and a stereo or 24-bit
//    one was re-wrapped as mono — half-speed audio the engine then transcribed.
// 2. It ran the engine and language Settings hold NOW, not the ones the meeting was transcribed
//    with, and nothing checked the result's language. The first fix then pinned the re-run to the
//    meeting's stored `languageCode` — which under Automatic, the default, is only the DETECTED
//    majority, so a minority-language line of a code-switched meeting was forced into the other
//    language. The re-run pins only what the meeting's own run pinned (`requestedLanguage`, written
//    by `apply(result:)`), and detects otherwise.
// 3. The splice dropped the re-run's Whisper metrics, so a hallucination over near-silence scored
//    clean and the orange flag it deserved vanished.
//
// Every assertion goes through `AppModel.reTranscribeSegment`, the call the Read view's context
// menu reaches through `requestSegmentReTranscription`.

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

/// What an injected engine saw. A class so the `@Sendable` override can record into it.
private final class EngineCall: @unchecked Sendable {
    var ran = false
    var clip: Data?
    var selection: MeetingTranscriptionSelection?
}

private func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
private func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

private func riffChunk(_ identifier: String, _ body: Data) -> Data {
    Data(identifier.utf8) + le32(UInt32(body.count)) + body + (body.count % 2 == 1 ? Data([0]) : Data())
}

/// A RIFF/WAVE file: `fmt `, then any `extra` chunks, then `data` holding `pcm`.
private func wavFile(
    channels: UInt16, sampleRate: UInt32, bitsPerSample: UInt16, extra: [Data] = [], pcm: Data
) -> Data {
    let blockAlign = channels * bitsPerSample / 8
    let format = le16(1) + le16(channels) + le32(sampleRate)
        + le32(sampleRate * UInt32(blockAlign)) + le16(blockAlign) + le16(bitsPerSample)
    let payload = ([riffChunk("fmt ", format)] + extra + [riffChunk("data", pcm)]).reduce(Data("WAVE".utf8), +)
    return Data("RIFF".utf8) + le32(UInt32(payload.count)) + payload
}

/// `seconds` of silent 16 kHz mono 16-bit audio in the canonical 44-byte layout.
private func silentWAV(seconds: Int) -> Data {
    var wav = WAVWriter.header(sampleRate: 16_000, dataByteCount: UInt32(seconds * 32_000))
    wav.append(Data(count: seconds * 32_000))
    return wav
}

/// A model with one completed meeting whose recording is `recording`, saved as `fileName`.
@MainActor
private func meetingWithRecording(
    _ recording: Data, fileName: String = "meeting.wav", segments: [TranscriptSegment],
    languageCode: String? = nil, engine: MeetingTranscriptionEngine? = nil, requestedLanguage: String? = nil
) throws -> (AppModel, UUID, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SegRerunF471-\(UUID().uuidString)")
    let id = UUID()
    let dir = root.appendingPathComponent("Recordings/\(id.uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try recording.write(to: dir.appendingPathComponent(fileName))
    let defaults = UserDefaults(suiteName: "F471.\(UUID().uuidString)")!
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    model.store.upsert(MeetingRecord(
        id: id, title: "M", recordingPath: "Recordings/\(id.uuidString)/\(fileName)",
        status: .completed, transcriptText: TranscriptFormatter.timestamped(segments),
        languageCode: languageCode, segments: segments, transcriptionEngine: engine,
        requestedLanguage: requestedLanguage
    ))
    return (model, id, root)
}

private func samples(in pcm: Data) -> [Int16] {
    stride(from: 0, to: pcm.count - 1, by: 2).map { offset in
        Int16(bitPattern: UInt16(pcm[pcm.startIndex + offset]) | UInt16(pcm[pcm.startIndex + offset + 1]) << 8)
    }
}

@MainActor
@Test("A re-run slices a WAV whose data chunk is not at byte 44 from the right audio (F471)")
func segmentReRunSlicesPastAListChunk() async throws {
    // Three seconds at 16 kHz mono 16-bit, each second a different constant, with ffmpeg's LIST/INFO
    // chunk between `fmt ` and `data` — which moves the audio from byte 44 to byte 78.
    let pcm = (0..<3).map { second in
        Data((0..<16_000).flatMap { _ in le16(UInt16(bitPattern: Int16(1_000 * (second + 1)))) })
    }.reduce(Data(), +)
    let list = riffChunk("LIST", Data("INFO".utf8) + riffChunk("ISFT", Data("Lavf61.7.100\0".utf8)))
    let segments = [seg("first", 0, 1), seg("second", 1, 2), seg("third", 2, 3)]
    let (model, id, root) = try meetingWithRecording(
        wavFile(channels: 1, sampleRate: 16_000, bitsPerSample: 16, extra: [list], pcm: pcm),
        fileName: "recording.wav", segments: segments
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let call = EngineCall()
    model.runTranscriptionEngineOverride = { _, clipURL in
        call.clip = try Data(contentsOf: clipURL)
        return TranscriptionResult(id: "x", text: "second", languageCode: "en", audioDuration: 1,
                                   confidence: nil, segments: [seg("second", 0, 1)])
    }

    await model.reTranscribeSegment(id: id, index: 1)

    let clip = try #require(call.clip)
    #expect(clip.count == 44 + 32_000)
    // Every sample is the second one's value. Sliced from byte 44, the clip starts 34 bytes early,
    // in the first second's audio, and ends 34 bytes short of the second's.
    #expect(Set(samples(in: clip.dropFirst(44))) == [2_000])
}

@MainActor
@Test("A re-run refuses a WAV it cannot slice as 16-bit mono, and the engine never runs (F471)")
func segmentReRunRefusesLayoutsItCannotSlice() async throws {
    for (channels, bits) in [(UInt16(2), UInt16(16)), (1, 24)] {
        let bytesPerSecond = 16_000 * Int(channels) * Int(bits) / 8
        let segments = [seg("first", 0, 1), seg("second", 1, 2)]
        let (model, id, root) = try meetingWithRecording(
            wavFile(channels: channels, sampleRate: 16_000, bitsPerSample: bits, pcm: Data(count: 2 * bytesPerSecond)),
            fileName: "recording.wav", segments: segments
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let call = EngineCall()
        model.runTranscriptionEngineOverride = { _, _ in
            call.ran = true
            return TranscriptionResult(id: "x", text: "junk", languageCode: "en", audioDuration: 1,
                                       confidence: nil, segments: [seg("junk", 0, 1)])
        }

        await model.reTranscribeSegment(id: id, index: 1)

        #expect(call.ran == false, "\(channels) ch, \(bits)-bit")
        #expect(model.store.meeting(id: id)?.segments[1].text == "second", "\(channels) ch, \(bits)-bit")
        #expect(model.alertMessage == SegmentReRunError.unsupportedAudioLayout.errorDescription,
                "\(channels) ch, \(bits)-bit")
    }
}

@MainActor
@Test("A re-run uses the engine and the pinned language the meeting was transcribed with, not Settings (F471)")
func segmentReRunUsesTheMeetingsEngineAndLanguage() async throws {
    let segments = [seg("我们开会", 0, 1), seg("然后讨论", 1, 2)]
    // Transcribed under an explicit Mandarin pin, which the meeting recorded as its requested
    // language; the stored "zh" is what the engine returned for it.
    let (model, id, root) = try meetingWithRecording(
        silentWAV(seconds: 2), segments: segments, languageCode: "zh", engine: .qwenBalanced,
        requestedLanguage: WhisperLanguage.chinese.rawValue
    )
    defer { try? FileManager.default.removeItem(at: root) }
    // Settings now say something else entirely — chosen for the NEXT meeting, not this one.
    model.selectedEngine = .whisperLarge
    model.selectedLanguage = .english
    let call = EngineCall()
    model.runTranscriptionEngineOverride = { selection, _ in
        call.selection = selection
        return TranscriptionResult(id: "x", text: "然后讨论预算", languageCode: "zh", audioDuration: 1,
                                   confidence: nil, segments: [seg("然后讨论预算", 0, 1)])
    }

    await model.reTranscribeSegment(id: id, index: 1)

    #expect(call.selection == MeetingTranscriptionSelection(engine: .qwenBalanced, language: .chinese))
    #expect(model.store.meeting(id: id)?.segments[1].text == "然后讨论预算")
    #expect(model.alertMessage == nil, "a Mandarin line in a Mandarin meeting needs no advisory")
}

@MainActor
@Test("A re-run detects its language when the meeting was transcribed automatically, whatever was detected (F471)")
func segmentReRunDetectsWhenTheMeetingWasTranscribedAutomatically() async throws {
    // A code-switched meeting transcribed under Automatic, the default. The stored "zh" is the
    // majority Whisper detected from the first 30 seconds (or the majority script Qwen's helper
    // counted) and says nothing about a pin; line 1 is the English minority. Pinning the re-run to
    // that "zh" hands Whisper `--language Chinese` and Qwen `language Chinese<asr_text>` for an
    // English line — this ticket's mistranslation, from the other side. nil is a meeting
    // transcribed before the requested language was recorded; "automatic" is one after.
    let requestedValues: [String?] = [nil, WhisperLanguage.automatic.rawValue]
    for requested in requestedValues {
        let label = Comment(rawValue: "requestedLanguage \(requested ?? "nil")")
        let segments = [seg("我们开会", 0, 1), seg("the deadline is Friday", 1, 2)]
        let (model, id, root) = try meetingWithRecording(
            silentWAV(seconds: 2), segments: segments, languageCode: "zh", engine: .qwenBalanced,
            requestedLanguage: requested
        )
        defer { try? FileManager.default.removeItem(at: root) }
        model.selectedEngine = .whisperLarge
        model.selectedLanguage = .english
        let call = EngineCall()
        model.runTranscriptionEngineOverride = { selection, _ in
            call.selection = selection
            return TranscriptionResult(id: "x", text: "The deadline is this Friday.", languageCode: "en",
                                       audioDuration: 1, confidence: nil,
                                       segments: [seg("The deadline is this Friday.", 0, 1)])
        }

        await model.reTranscribeSegment(id: id, index: 1)

        #expect(call.selection == MeetingTranscriptionSelection(engine: .qwenBalanced, language: .automatic), label)
        #expect(model.store.meeting(id: id)?.segments[1].text == "The deadline is this Friday.", label)
        // The advisory stays keyed on the language the transcript came back in, so a line in the
        // other script is still said under Automatic — here, the switch the audio really has.
        #expect(model.alertMessage == LanguageConsistency.segmentRerunWarning(
            meetingLanguage: .chinese, replacementText: "The deadline is this Friday."
        ), label)
    }
}

@MainActor
@Test("A transcription records the language it was asked for, and the re-run pins only that (F471)")
func aTranscriptionRecordsItsRequestedLanguageAndTheReRunPinsOnlyThat() async throws {
    // Through `apply(result:)`, the one write every finished transcription passes through
    // (`performTranscription` hands it the queued Settings snapshot), and then through the re-run.
    // Both meetings come back "zh" from the engine, so their stored code is the same; only one
    // asked for it, and only that one is re-run under a pin.
    let cases: [(requested: WhisperLanguage, rerunsIn: WhisperLanguage)] = [
        (.chinese, .chinese), (.automatic, .automatic),
    ]
    for (requested, rerunsIn) in cases {
        let (model, id, root) = try meetingWithRecording(silentWAV(seconds: 2), segments: [])
        defer { try? FileManager.default.removeItem(at: root) }
        model.apply(
            result: TranscriptionResult(id: "x", text: "我们开会 然后讨论", languageCode: "zh", audioDuration: 2,
                                        confidence: nil, segments: [seg("我们开会", 0, 1), seg("然后讨论", 1, 2)]),
            to: id, requestedLanguage: requested, engine: .qwenBalanced
        )
        #expect(model.store.meeting(id: id)?.requestedLanguage == requested.rawValue, "\(requested)")
        #expect(model.store.meeting(id: id)?.languageCode == "zh", "\(requested)")

        let call = EngineCall()
        model.runTranscriptionEngineOverride = { selection, _ in
            call.selection = selection
            return TranscriptionResult(id: "x", text: "然后讨论预算", languageCode: "zh", audioDuration: 1,
                                       confidence: nil, segments: [seg("然后讨论预算", 0, 1)])
        }
        await model.reTranscribeSegment(id: id, index: 1)

        #expect(call.selection == MeetingTranscriptionSelection(engine: .qwenBalanced, language: rerunsIn), "\(requested)")
    }
}

@MainActor
@Test("A re-run line in the meeting's other language is put in and said, not spliced silently (F471)")
func segmentReRunSaysWhenTheNewLineIsInTheOtherLanguage() async throws {
    let segments = [seg("我们开会", 0, 1), seg("然后讨论", 1, 2)]
    let (model, id, root) = try meetingWithRecording(
        silentWAV(seconds: 2), segments: segments, languageCode: "zh", engine: .whisperLarge
    )
    defer { try? FileManager.default.removeItem(at: root) }
    model.runTranscriptionEngineOverride = { _, _ in
        TranscriptionResult(id: "x", text: "Then we discuss.", languageCode: "zh", audioDuration: 1,
                            confidence: nil, segments: [seg("Then we discuss.", 0, 1)])
    }

    await model.reTranscribeSegment(id: id, index: 1)

    #expect(model.store.meeting(id: id)?.segments[1].text == "Then we discuss.")
    let alert = try #require(model.alertMessage, "the splice is said, not silent")
    #expect(alert == LanguageConsistency.segmentRerunWarning(
        meetingLanguage: .chinese, replacementText: "Then we discuss."
    ))
}

@MainActor
@Test("A re-run keeps the replacement's quality metrics and re-derives the header confidence (F471)")
func segmentReRunKeepsTheReplacementsMetrics() async throws {
    let scored = { (text: String, start: Double) in
        TranscriptSegment(speaker: nil, start: start, end: start + 1, text: text,
                          avgLogprob: -0.2, noSpeechProb: 0.01, compressionRatio: 1.2)
    }
    let segments = [scored("first", 0), scored("second wrong", 1), scored("third", 2)]
    let (model, id, root) = try meetingWithRecording(silentWAV(seconds: 3), segments: segments)
    defer { try? FileManager.default.removeItem(at: root) }
    model.store.update(id: id) { $0.confidence = 1.0 }
    model.runTranscriptionEngineOverride = { _, _ in
        TranscriptionResult(id: "x", text: "Thank you.", languageCode: "en", audioDuration: 1, confidence: nil,
                            segments: [TranscriptSegment(speaker: nil, start: 0, end: 1, text: "Thank you.",
                                                         avgLogprob: -0.4, noSpeechProb: 0.95, compressionRatio: 0.8)])
    }

    await model.reTranscribeSegment(id: id, index: 1)

    let updated = try #require(model.store.meeting(id: id))
    #expect(updated.segments[1].noSpeechProb == 0.95)
    let quality = TranscriptQuality.review(updated.segments)
    #expect(quality.flagged.map(\.index) == [1], "the hallucination over near-silence is flagged")
    #expect(updated.confidence == quality.confidence, "the header says what the lines say")
    #expect(updated.confidence != 1.0)
}
