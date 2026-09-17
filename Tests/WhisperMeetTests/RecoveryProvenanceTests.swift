import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F273 — transcribing a recovered meeting destroyed the only record that it was recovered.
//
// Observed in the user's library, not hypothesised: a real 63-minute meeting whose folder has
// `meeting.wav` absent and `meeting-recovered.wav` present — so `stop()` never completed and the
// rebuild ran — now reads `status: completed`, `errorMessage: None`. `performTranscription` clears
// `errorMessage` twice, once on start and once on success, and that field was the only place the
// provenance lived.
//
// The lost sentence carried a caveat about the AUDIO, which is the half that matters: a rebuilt
// capture has no per-track start offsets, because the manifest is written in `stop()` and recovery
// zero-aligns the channels. After transcription the meeting presented as ordinary.
//
// So provenance stops being prose in a field something else owns. A structural fact survives
// anything that clears a message, and the sentence is generated in one place — which is also how
// it reaches `notes.md` through F281's caveats list.

@Test("A rebuilt meeting says so structurally, not in a message another path clears")
func rebuiltProvenanceIsStructural() {
    let record = MeetingRecord(
        title: "Recovered Meeting",
        status: .completed,
        recoverySource: RecoveredRecording.Source.rebuiltSourceTracks.rawValue
    )
    let caveats = MeetingStore.caveats(for: record)
    #expect(caveats.contains { $0.contains("rebuilt from its raw microphone and system tracks") })
    // The audio caveat F273 identified as the half that matters.
    #expect(caveats.contains { $0.contains("aligned to the start of the file") })
}

@Test("A preserved recovery says the weaker thing, because its channels are intact")
func preservedProvenanceSaysLess() {
    // `existingCapture` means the recording was already finalized and only the index had lost it,
    // so there is no alignment caveat to make — claiming one would be as wrong as omitting it.
    let record = MeetingRecord(
        title: "Recovered Meeting",
        status: .completed,
        recoverySource: RecoveredRecording.Source.existingCapture.rawValue
    )
    let caveats = MeetingStore.caveats(for: record)
    #expect(caveats.contains { $0.contains("recovered after an interruption") })
    #expect(!caveats.contains { $0.contains("aligned to the start of the file") })
}

@Test("A meeting that was never recovered says nothing")
func ordinaryMeetingHasNoProvenance() {
    let record = MeetingRecord(title: "Ordinary", status: .completed)
    #expect(MeetingStore.caveats(for: record).isEmpty)
}

@Test("An unknown recovery source is ignored rather than rendered")
func unknownRecoverySourceIsIgnored() {
    // F250's rule one file over: a value this build does not know must not make the library
    // unreadable, and must not print a raw identifier at the user either.
    let record = MeetingRecord(
        title: "From the future",
        status: .completed,
        recoverySource: "somethingThisBuildHasNeverHeardOf"
    )
    #expect(MeetingStore.caveats(for: record).isEmpty)
}

@Test("A record written before this field existed still decodes")
func olderRecordDecodesWithoutProvenance() throws {
    let fixture = #"""
    {"id":"7C1D0E52-1111-4B0A-9A2E-555555555555","title":"Old","createdAt":700000000,
     "duration":0,"recordingPath":"","status":"recorded","transcriptText":"","segments":[]}
    """#
    let record = try JSONDecoder().decode(MeetingRecord.self, from: Data(fixture.utf8))
    #expect(record.recoverySource == nil)
}

@Test("Transcribing a recovered meeting keeps its provenance and drops the stale-audio notice")
@MainActor
func transcriptionKeepsProvenanceAndClearsStaleness() throws {
    // The two halves of what transcription owes a recovered meeting, and they point opposite ways.
    //
    // Provenance must SURVIVE: the recording was rebuilt whatever happens to its transcript, and
    // F273 is the report of it being erased.
    //
    // The stale-transcript notice must be CLEARED: after F267 rebuilds the audio, the old
    // transcript describes a file that no longer exists — but once transcribed again it describes
    // the current one, so keeping the notice would be a false claim in the other direction. My own
    // F267 comment said "cleared the next time the meeting is transcribed" and nothing did it.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("Provenance-\(UUID().uuidString)", isDirectory: true)
    let folder = root.appendingPathComponent("Recordings/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try WAVWriter.wavData(from: [Float](repeating: 0.2, count: 48_000), sampleRate: 48_000)
        .write(to: folder.appendingPathComponent("meeting-recovered.wav"))

    let suite = "WhisperMeet.Provenance.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: suite)!
    )
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id,
        title: "Recovered Meeting",
        duration: 1,
        recordingPath: "Recordings/\(folder.lastPathComponent)/meeting-recovered.wav",
        status: .recorded,
        errorMessage: "Recovered from source audio after an interruption.",
        recoverySource: RecoveredRecording.Source.rebuiltSourceTracks.rawValue,
        staleTranscriptWarning: "This transcript was made from an earlier version of the audio."
    ))

    // `apply(result:to:)` is the function under test — it owns the `errorMessage = nil` and
    // `staleTranscriptWarning = nil` lines — and calling it directly is synchronous.
    //
    // The first version of this test drove `beginTranscription` and polled for `.completed` with a
    // 5 s budget, then asserted regardless of whether the wait had succeeded. It passed here and
    // failed on the CI runner, where the queue needed longer, with two confusing assertion
    // failures instead of one clear timeout. A test that asserts a consequence without requiring
    // its precondition reports the wrong thing when it is slow, and a fixed budget makes "slow"
    // a property of the host rather than of the code. Driving the real queue added no coverage of
    // the change and one way to be wrong.
    model.apply(
        result: TranscriptionResult(
            id: "stub", text: "Hello from the rebuilt audio.", languageCode: "en",
            audioDuration: 1, confidence: 0.9,
            segments: [TranscriptSegment(
                speaker: nil, start: 0, end: 1, text: "Hello from the rebuilt audio."
            )]
        ),
        to: id
    )

    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.status == .completed)
    // Survives — the whole of F273.
    #expect(meeting.recoverySource == RecoveredRecording.Source.rebuiltSourceTracks.rawValue)
    #expect(MeetingStore.caveats(for: meeting).contains {
        $0.contains("aligned to the start of the file")
    })
    // Cleared — the transcript now describes the audio that is actually there.
    #expect(meeting.staleTranscriptWarning == nil)
}

@Test("The recording-caveat family excludes the transcript ones, so nothing double-renders")
func recoveryCaveatsExcludeTranscriptWarnings() {
    // The detail view renders `recoveryCaveats` as a list while `transcriptSection` still renders
    // the alignment and language warnings itself. Overlapping the two would show them twice.
    let record = MeetingRecord(
        title: "Everything at once",
        status: .completed,
        alignmentWarning: "No seekable timestamps.",
        recoveryWarning: "Audio stops at 12:30.",
        recoverySource: RecoveredRecording.Source.rebuiltSourceTracks.rawValue,
        staleTranscriptWarning: "Transcript is from an earlier version.",
        languageWarning: "Script disagrees with the selected language."
    )
    let recording = MeetingStore.recoveryCaveats(for: record)
    #expect(recording.count == 3)
    #expect(!recording.contains("No seekable timestamps."))
    #expect(!recording.contains("Script disagrees with the selected language."))
    // The full list, which notes.md uses, does carry all five.
    #expect(MeetingStore.caveats(for: record).count == 5)
    // Recording caveats first: they qualify the audio the transcript came from.
    let all = MeetingStore.caveats(for: record)
    #expect(all.prefix(3) == recording.prefix(3))
}
