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

/// A library whose banner is up over a rename, with a completed Review whose new transcript is held.
@MainActor
private func modelWithAHeldResult() throws -> (AppModel, URL, review: UUID) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F987-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    let store = model.store
    let standup = UUID(), review = UUID()
    store.upsert(MeetingRecord(id: standup, title: "Standup", status: .completed))
    store.upsert(MeetingRecord(id: review, title: "Review", recordingPath: "none", status: .completed,
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
    #expect(card.contains("AppModel.heldResultCardDetail"))
}
