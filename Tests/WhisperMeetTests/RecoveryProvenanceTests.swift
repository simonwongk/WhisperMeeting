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

// MARK: - F303: the recovery branch F273 missed

@MainActor
@Test("A recovered import macOS cannot verify still carries its provenance (F303)")
func unverifiableImportCarriesProvenance() async throws {
    // F273's principle applied to the one branch it skipped. `performStartupRecovery`'s
    // unverified-import path upserted with `errorMessage` and none of the three fields
    // `recoveryCaveats(for:)` renders — so this meeting showed no caveat at all, and the sentence
    // explaining why it is `.failed` lived only in the field transcription clears twice.
    //
    // Its sibling branch two lines below sets `recoveryWarning` and `recoverySource`, which is what
    // makes this an omission rather than a decision.
    //
    // Driven through the real recovery rather than by constructing a record, because the defect was
    // in which arguments one call site passed — a hand-built `MeetingRecord` would have asserted my
    // own understanding of the branch instead of the branch.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("UnverifiableImport-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // A protected imported file with bytes but no decodable audio: non-empty so recovery treats the
    // folder as an interrupted import, undecodable so `loadDuration` returns 0 and the unverified
    // branch is the one that fires.
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("not audio, but not empty either".utf8)
        .write(to: folder.appendingPathComponent("recording.m4a"))

    let suite = "F303.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: suite)!
    )
    await model.performStartupRecovery()

    let meeting = try #require(
        model.store.meeting(id: id),
        "the interrupted import should have been preserved as an entry at all"
    )
    #expect(meeting.status == .failed, "this is the unverified-import branch, not the ordinary one")

    // The assertion that fails before the fix: the meeting renders no recording caveat, so nothing
    // on screen or in `notes.md` says it came from an interrupted import.
    let caveats = MeetingStore.recoveryCaveats(for: meeting)
    #expect(!caveats.isEmpty, "a recovered meeting with no caveat cannot say it was recovered")
    #expect(meeting.recoverySource == RecoveredRecording.Source.importedRecording.rawValue)
}

@MainActor
@Test("That provenance survives the transcription that clears the error message (F303)")
func unverifiableImportProvenanceSurvivesClearing() throws {
    // The half that makes it worth fixing rather than merely inconsistent. `performTranscription`
    // clears `errorMessage` on start and on success, and the comment at the branch says
    // transcription is deliberately still offered for a `.failed` recovery "because the surviving
    // audio may still be worth transcribing". Taking that offer used to leave a failure with no
    // stated reason and no record of where it came from.
    //
    // Simulated by clearing the field the way transcription does, rather than driving a real
    // transcription: the production line under test is the *upsert's* arguments, and driving a
    // model subprocess would add a host dependency for no coverage — the mistake this ticket's
    // predecessor shipped and had to fix.
    var meeting = MeetingRecord(
        id: UUID(),
        title: "Unverified Import",
        createdAt: Date(),
        status: .failed,
        errorMessage: "WhisperMeet preserved this interrupted import, but macOS could not verify it.",
        recoverySource: RecoveredRecording.Source.importedRecording.rawValue
    )
    #expect(!MeetingStore.recoveryCaveats(for: meeting).isEmpty)

    meeting.errorMessage = nil   // exactly what AppModel.swift:3515 and :3562 do
    let after = MeetingStore.recoveryCaveats(for: meeting)
    #expect(!after.isEmpty, "provenance must not live in a field transcription owns")
    #expect(after.contains { $0.contains("recovered after an interruption") })
}

@MainActor
@Test("An interrupted import that is entirely empty also carries its provenance (F303)")
func emptyImportCarriesProvenance() async throws {
    // The *other* unverified-import branch, and the two differ in a way that explains the original
    // omission. `importedRecording(in:)` requires a non-empty file, so a zero-byte one makes
    // `recover` return nil and lands in the `guard let recovered else` path — which has no
    // `RecoveredRecording` to read a source from, while its sibling does. One had
    // `recovered.source` to hand and the other did not, so the field was set in neither.
    //
    // Both are reachable and both preserve a real user file, so both need the provenance.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("EmptyImport-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // Zero bytes: the candidate exists and is protected, but there is nothing to recover.
    try Data().write(to: folder.appendingPathComponent("recording.m4a"))

    let suite = "F303.empty.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: suite)!
    )
    await model.performStartupRecovery()

    let meeting = try #require(model.store.meeting(id: id), "the empty import must still be kept")
    #expect(meeting.status == .failed)
    #expect(meeting.recoverySource == RecoveredRecording.Source.importedRecording.rawValue)
    #expect(!MeetingStore.recoveryCaveats(for: meeting).isEmpty)
}

// MARK: - F305: a false sentence, and a reason that still dies with the message

@Test("An imported recovery is never told it kept source tracks it never had (F305)")
func importedRecoverySaysNothingAboutSourceTracks() {
    // `provenanceCaveat` grouped `.importedRecording` with `.existingCapture` and told both that
    // "the original recording and its source tracks were preserved". An import has no source
    // tracks — the function that detects one says so itself: "An imported recording keeps a single
    // `recording.<ext>` file and no raw source tracks".
    //
    // F303 made this reach further by giving every recovered import the sentence, including the two
    // `.failed` unverified ones, where "the original recording … preserved" reads as reassurance
    // about a file macOS declined to verify.
    let imported = MeetingRecord(
        id: UUID(), title: "Unverified Import", createdAt: Date(), status: .failed,
        recoverySource: RecoveredRecording.Source.importedRecording.rawValue
    )
    let caveats = MeetingStore.recoveryCaveats(for: imported)
    #expect(!caveats.isEmpty, "an import still needs to say it was recovered")
    // The CLAIM, not the phrase. My first version asserted the words "source tracks" were absent,
    // and the corrected sentence contains them while denying them — "there are no separate source
    // tracks". A substring test on a phrase that appears in both the true and the false version of
    // a sentence cannot tell them apart.
    #expect(
        !caveats.contains { $0.contains("its source tracks were preserved") },
        "an import has no source tracks, so nothing may claim they were kept: \(caveats)"
    )
    #expect(
        caveats.contains { $0.contains("no separate source tracks") },
        "and it should say so, rather than going quiet about it: \(caveats)"
    )

    // The capture case still claims it, because for a capture it is true.
    let capture = MeetingRecord(
        id: UUID(), title: "m", createdAt: Date(),
        recoverySource: RecoveredRecording.Source.existingCapture.rawValue
    )
    #expect(
        MeetingStore.recoveryCaveats(for: capture)
            .contains { $0.contains("its source tracks were preserved") }
    )
}

@Test("Why a recovery happened survives the message being cleared (F305, F274)")
func sleepInterruptionSurvivesTranscription() {
    // F274 appended "The recording stopped because this Mac went to sleep." to `errorMessage`, and
    // said so deliberately: "No new field for it: the message that already explains the recovery
    // says which interruption it was." But `performTranscription` clears `errorMessage` on start
    // and on success — so transcribing a recovered meeting keeps THAT it was recovered and erases
    // WHY. F273's defect, for a second fact, decided one commit after F273 ruled it out.
    var meeting = MeetingRecord(
        id: UUID(), title: "m", createdAt: Date(),
        errorMessage: "Recovered after an interruption. The recording stopped because this Mac went to sleep.",
        recoverySource: RecoveredRecording.Source.rebuiltSourceTracks.rawValue,
        recoveryInterruption: RecoveryInterruption.systemSleep.rawValue
    )
    #expect(MeetingStore.recoveryCaveats(for: meeting).contains { $0.contains("went to sleep") })

    meeting.errorMessage = nil   // exactly what AppModel.swift:3515 and :3562 do
    #expect(
        MeetingStore.recoveryCaveats(for: meeting).contains { $0.contains("went to sleep") },
        "the reason has to outlive the message, which is this whole family's rule"
    )
}

@Test("An unrecognised interruption renders nothing rather than a raw identifier (F305)")
func unknownInterruptionIsIgnored() {
    // F250's rule, applied to the new field: a value a newer build writes must decode and be
    // ignored, never shown. A raw identifier in front of a user is worse than silence.
    let meeting = MeetingRecord(
        id: UUID(), title: "m", createdAt: Date(),
        recoverySource: RecoveredRecording.Source.rebuiltSourceTracks.rawValue,
        recoveryInterruption: "somethingAFutureBuildInvented"
    )
    let caveats = MeetingStore.recoveryCaveats(for: meeting)
    #expect(!caveats.isEmpty, "the provenance sentence still renders")
    #expect(!caveats.contains { $0.contains("somethingAFutureBuildInvented") })
}
