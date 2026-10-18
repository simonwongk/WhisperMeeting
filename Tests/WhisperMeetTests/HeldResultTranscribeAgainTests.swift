import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F987 — a transcription whose result save lost to another copy of the app twice is held beside the
// conflict banner until it is answered (F885). The list's copy of the meeting has not changed, so the
// meeting read as idle: no status card, and Transcribe Again enabled — a second run of a transcription
// whose first result had not even been saved. F935 deferred this guard to F843 and F843 back to F935.

@MainActor
private func otherCopyCommits(in root: URL, _ change: ([MeetingRecord]) -> [MeetingRecord]) throws {
    let rival = BackupJSONStore<[MeetingRecord]>(
        primaryURL: root.appendingPathComponent("meetings.json"),
        backupURL: root.appendingPathComponent("meetings.backup.json"),
        writer: "ffff9999",
        recordCount: { $0.count }
    )
    let seen = try rival.load()
    _ = try rival.save(change(seen?.value ?? []), expecting: seen?.token)
}

/// A library whose banner is up over a rename, with a Review whose new transcript is held: `.completed`
/// with a first transcript (a Transcribe Again), or `.recorded` (an imported meeting's first run).
@MainActor
private func modelWithAHeldResult(listStatus: MeetingStatus = .completed) throws -> (AppModel, URL, review: UUID) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F987-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // Both engines read as installed, so a refusal below is the held result's and not a missing model's.
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!,
                         whisperExecutable: { URL(fileURLWithPath: "/usr/bin/true") }, qwenInstalled: { true })
    model.runTranscriptionEngineOverride = { _, _ in
        TranscriptionResult(id: "F987", text: "A third transcript.", languageCode: "en", audioDuration: 1,
                            confidence: nil, segments: [])
    }
    let store = model.store
    let standup = UUID(), review = UUID()
    store.upsert(MeetingRecord(id: standup, title: "Standup", status: .completed))
    store.upsert(MeetingRecord(id: review, title: "Review", recordingPath: "Recordings/x/meeting.wav", status: listStatus,
                               transcriptText: "The first transcript."))
    try otherCopyCommits(in: root) { $0.map { var r = $0; if r.id == standup { r.title = "Renamed there" }; return r } }
    store.update(id: standup) { $0.title = "Renamed here" }
    try #require(store.conflictOffer != nil, "fixture: the rename should have lost and been offered back")

    // The other copy saves before the result's save and again before its re-save (F885's shape).
    try otherCopyCommits(in: root) { $0 + [MeetingRecord(title: "The other copy's first", status: .recorded)] }
    var saves = 0
    store.beforeIndexSaveForTesting = {
        saves += 1
        if saves == 2 {
            try? otherCopyCommits(in: root) { $0 + [MeetingRecord(title: "The other copy's second", status: .recorded)] }
        }
    }
    store.update(id: review, as: .result) { $0.transcriptText = "The second transcript."; $0.status = .completed }
    store.beforeIndexSaveForTesting = nil
    try #require(store.heldResultCount(for: review) == 1, "fixture: the transcript should be held")
    try #require(store.meeting(id: review)?.transcriptText == "The first transcript.", "fixture: the held result reached the list")
    return (model, root, review)
}

@MainActor
@Test("A meeting whose result is held is not offered Transcribe Again, and shows its status card (F987)")
func aHeldResultBlocksTranscribeAgainAndShowsTheCard() throws {
    let (model, root, review) = try modelWithAHeldResult()
    defer { try? FileManager.default.removeItem(at: root) }
    let meeting = try #require(model.store.meeting(id: review))

    #expect(model.transcribeAgainBlockedReason(for: review) == AppModel.heldResultNotSavedYet,
            "Transcribe Again is offered over a result that has not been saved")
    #expect(model.showsTranscriptionStatusCard(for: meeting), "the held meeting reads as idle")
    #expect(model.isResultHeld(review))

    // The answer saves it, and the meeting is settled again.
    model.store.keepConflictedEdit()
    #expect(model.store.heldResultCount(for: review) == 0)
    let saved = try #require(model.store.meeting(id: review))
    #expect(saved.transcriptText == "The second transcript.")
    #expect(model.transcribeAgainBlockedReason(for: review) == nil)
    #expect(!model.showsTranscriptionStatusCard(for: saved))
}

@Test("The status card says a held result is waiting, and offers no Transcribe while it is (F987)")
func statusCardRendersAHeldResult() throws {
    let content = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let start = try #require(content.range(of: "private func statusCard(_ meeting: MeetingRecord) -> some View {"))
    let card = content[start.lowerBound...].prefix(4_000)
    #expect(card.contains("model.isResultHeld(meeting.id)"), "the card does not ask whether a result is held")
    #expect(card.contains("model.heldResultCardDetail"), "the card's line does not follow the library's writability")
}

// MARK: - Round 2 (the review of lane U, finding 2)

// The review's probe R2: the block was on two buttons. An imported meeting whose first transcript is
// held still reads `.recorded`, so Transcribe N Ready Meetings counted it and queued it again.
@MainActor
@Test("A meeting whose finished transcript is held is not counted as ready to transcribe (F987, round 2)")
func aHeldResultIsNotReadyToTranscribe() throws {
    let (model, root, review) = try modelWithAHeldResult(listStatus: .recorded)
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(model.store.meeting(id: review)?.status == .recorded)
    try #require(model.transcribeAgainBlockedReason(for: review) == AppModel.heldResultNotSavedYet)

    #expect(!model.readyToTranscribeMeetings.contains { $0.id == review },
            "Transcribe N Ready Meetings (beginTranscriptionForAllReady) would run the held meeting again")
}

// The model refuses too, so no caller — the batch, a status card, Stop & Transcribe — can start one.
@MainActor
@Test("beginTranscription refuses a meeting whose result is held, and says why (F987, round 2)")
func beginTranscriptionRefusesAHeldMeeting() throws {
    let (model, root, review) = try modelWithAHeldResult(listStatus: .recorded)
    defer { try? FileManager.default.removeItem(at: root) }
    model.alertMessage = nil

    model.beginTranscription(id: review)

    #expect(!model.isQueuedForTranscription(review) && !model.hasActiveTranscription,
            "a second transcription of a meeting whose first is not saved was started")
    #expect(model.alertMessage == AppModel.heldResultNotSavedYet)
}

// In a library that cannot be written the banner says the held work "cannot be saved"
// (`ConflictOffer`'s held-results sentence); the card must not promise that either answer saves it.
@MainActor
@Test("The held-result card line follows the banner: no promise to save in a read-only library (F987, round 2)")
func heldResultCardLineFollowsWritability() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F987-ro-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // Both index files unreadable: the library opens read-only, as F187/F321's tests set it up.
    try Data("broken-primary".utf8).write(to: root.appendingPathComponent("meetings.json"))
    try Data("broken-backup".utf8).write(to: root.appendingPathComponent("meetings.backup.json"))
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    try #require(model.store.isDegraded, "fixture: the library should open read-only")

    #expect(!model.heldResultCardDetail.contains("either saves it"), "\(model.heldResultCardDetail)")
    #expect(model.heldResultCardDetail == AppModel.heldResultCardDetailReadOnly)

    let (writable, writableRoot, _) = try modelWithAHeldResult()
    defer { try? FileManager.default.removeItem(at: writableRoot) }
    #expect(writable.heldResultCardDetail == AppModel.heldResultCardDetailWritable)
}
