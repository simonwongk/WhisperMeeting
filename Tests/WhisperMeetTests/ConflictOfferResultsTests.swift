import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F662 — while a conflict offer is outstanding, `editMutationIsAllowed()` (F619) refused every meeting
// write, silently. That was meant for the person's own edits, which the banner explains. But the app's
// own finished work goes through the same `upsert`/`update`, and since F642 any lost save can raise an
// offer: Stop pressed while the banner was up saved the audio and left the meeting out of the list
// (found as an orphan at the next launch), and a transcript or summary finishing meanwhile was thrown
// away. These drive the real `AppModel` paths over two `BackupJSONStore` writers on one temp root —
// this window's store, and another copy of the app committing to the same files.

@MainActor
private func makeModel() throws -> (AppModel, URL, () -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F662-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = testSuiteName()
    let defaults = try #require(UserDefaults(suiteName: suite))
    let recorder = AudioCaptureEngine(
        stoppingCapture: {}, finishingTracks: {}, preservingPartialTracks: {},
        startingCapture: { _, _, _ in }, restartingCapture: { _ in }, directory: root
    )
    let model = AppModel(
        store: MeetingStore(rootDirectory: root), recorder: recorder, defaults: defaults,
        whisperExecutable: { nil }, qwenInstalled: { false }
    )
    return (model, root, {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    })
}

/// Another copy of the app reading what is on disk and committing `change` of it.
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

private let renamedHere = "Standup, renamed here"
private let renamedThere = "Standup, renamed by the other copy"

/// The banner, up: this window renamed `id`, and another copy renamed it first.
@MainActor
private func raiseOffer(on store: MeetingStore, root: URL, id: UUID) throws {
    try otherCopyCommits(in: root) { records in
        records.map { record in
            var record = record
            if record.id == id { record.title = renamedThere }
            return record
        }
    }
    store.update(id: id) { $0.title = renamedHere }
    let offer = try #require(store.conflictOffer, "fixture: the rename should have lost and been offered back")
    try #require(offer.delta.contains { $0.id == id && $0.title == renamedHere })
}

@MainActor
private func onDisk(_ root: URL, _ id: UUID) -> MeetingRecord? {
    MeetingStore(rootDirectory: root).meeting(id: id)
}

private let transcript = TranscriptionResult(
    id: "F662", text: "We agreed to ship on Friday.", languageCode: "en",
    audioDuration: 2, confidence: nil, segments: []
)

@MainActor
@Test("Stop pressed while the conflict banner is up lists and saves the meeting, and the banner stays (F662)")
func stopDuringAnOfferIsIndexed() async throws {
    let (model, root, cleanup) = try makeModel()
    defer { cleanup() }
    let store = model.store
    let standup = UUID()
    store.upsert(MeetingRecord(id: standup, title: "Standup", status: .completed))

    model.recordingTitle = "Board call"
    await model.startRecording()
    let id = try #require(model.activeMeetingID)
    try model.recorder.beginTestTrackSession(in: store.recordingDirectoryURL(for: id))
    try model.recorder.writeTestFrames(system: 48_000 * 2, microphone: 48_000 * 2, systemStart: 0, microphoneStart: 0)
    try raiseOffer(on: store, root: root, id: standup)

    let saved = try #require(await model.stopRecording(title: model.recordingTitle))

    #expect(saved == id)
    #expect(store.meeting(id: id)?.title == "Board call", "the finished recording was left out of the list")
    #expect(onDisk(root, id)?.title == "Board call", "the finished recording never reached the index")
    let offer = try #require(store.conflictOffer, "saving the recording must not answer the banner for the person")
    #expect(offer.delta.contains { $0.id == standup && $0.title == renamedHere })
    #expect(store.writeConflict == nil)

    // Either answer keeps it.
    store.discardConflictedEdit()
    #expect(onDisk(root, id)?.title == "Board call")
    #expect(onDisk(root, standup)?.title == renamedThere)
}

@MainActor
@Test("A transcript finishing while the banner is up is saved, and neither answer loses it (F662)", arguments: [true, false])
func transcriptDuringAnOfferSurvivesEitherAnswer(keep: Bool) throws {
    let (model, root, cleanup) = try makeModel()
    defer { cleanup() }
    let store = model.store
    let id = UUID()
    store.upsert(MeetingRecord(id: id, title: "Standup", status: .processing))
    try raiseOffer(on: store, root: root, id: id)

    // The same meeting the banner is about: Keep must not put back a copy from before the result.
    model.apply(result: transcript, to: id)

    #expect(store.meeting(id: id)?.transcriptText == transcript.text, "the transcript was thrown away")
    #expect(onDisk(root, id)?.transcriptText == transcript.text, "the transcript never reached the index")
    try #require(store.conflictOffer != nil)

    if keep { store.keepConflictedEdit() } else { store.discardConflictedEdit() }

    let saved = try #require(onDisk(root, id))
    #expect(saved.title == (keep ? renamedHere : renamedThere))
    #expect(saved.transcriptText == transcript.text, keep ? "Keep put back a copy from before the transcript" : "Use the Other Copy lost the transcript")
    #expect(saved.status == .completed)
    #expect(store.writeConflict == nil)
}

private final class StubSummarizer: MeetingSummarizer, @unchecked Sendable {
    func summarize(transcript: String, language: String?, style: SummaryStyle, template: MeetingTemplate) async throws -> MeetingSummary {
        MeetingSummary(summary: "Ship on Friday.", keyPoints: ["Friday"], actionItems: [])
    }
}

@MainActor
@Test("A summary finishing while the banner is up is saved, and Keep carries it (F662)")
func summaryDuringAnOfferIsSaved() async throws {
    let (model, root, cleanup) = try makeModel()
    defer { cleanup() }
    let store = model.store
    model.makeSummarizer = { _, _ in StubSummarizer() }
    let id = UUID()
    store.upsert(MeetingRecord(id: id, title: "Standup", status: .completed, transcriptText: transcript.text))
    try raiseOffer(on: store, root: root, id: id)

    await model.performSummarization(
        id: id, engine: .local, apiKey: "", transcript: transcript.text, language: "en", style: .balanced
    )

    #expect(store.meeting(id: id)?.summary?.summary == "Ship on Friday.", "the summary was thrown away")
    #expect(onDisk(root, id)?.summary?.summary == "Ship on Friday.")
    store.keepConflictedEdit()
    #expect(onDisk(root, id)?.title == renamedHere)
    #expect(onDisk(root, id)?.summary?.summary == "Ship on Friday.", "Keep put back a copy from before the summary")
}

/// A result saved while the banner is up can itself lose: the other copy saved again in between.
/// Before F662 there was no such save; with one, `beginConflictRecovery()`'s single-offer guard would
/// have left the raw conflict and the generic "could not be saved" alert dangling over a stale token —
/// F619's original problem. The race folds into the offer already up — and the result itself is made
/// again to the copy the re-read found and saved, not offered as the person's change. The first cut
/// offered it ("Keep My Edit saves your changes to “Review”"), so Use the Other Copy erased a finished
/// transcript (the lane-Q review's probe, now this test).
@MainActor
@Test("A result whose own save loses while the banner is up is saved onto the re-read copy, and neither answer drops it (F662)", arguments: [true, false])
func aResultThatLosesAgainIsSavedOntoTheReloadedCopy(keep: Bool) throws {
    let (model, root, cleanup) = try makeModel()
    defer { cleanup() }
    let store = model.store
    let standup = UUID(), review = UUID(), third = UUID()
    store.upsert(MeetingRecord(id: standup, title: "Standup", status: .completed))
    store.upsert(MeetingRecord(id: review, title: "Review", status: .processing))
    try raiseOffer(on: store, root: root, id: standup)
    // The other copy saves again — a meeting of its own — so this window's token is stale once more.
    try otherCopyCommits(in: root) { $0 + [MeetingRecord(id: third, title: "The other copy's meeting", status: .recorded)] }

    model.apply(result: transcript, to: review)

    #expect(store.writeConflict == nil, "the second race was left raw instead of folded into the offer")
    let offer = try #require(store.conflictOffer)
    #expect(offer.delta.contains { $0.id == standup && $0.title == renamedHere }, "the first offer's edit was lost")
    #expect(!offer.delta.contains { $0.id == review }, "the result was offered as the person's change: \(offer.message)")
    #expect(store.meeting(id: third) != nil, "the library was not re-read")
    #expect(store.meeting(id: review)?.transcriptText == transcript.text, "the result is not in the list")
    #expect(onDisk(root, review)?.transcriptText == transcript.text, "the result was not saved onto the re-read library")

    if keep { store.keepConflictedEdit() } else { store.discardConflictedEdit() }

    #expect(store.writeConflict == nil)
    #expect(store.conflictOffer == nil)
    #expect(onDisk(root, standup)?.title == (keep ? renamedHere : renamedThere))
    #expect(onDisk(root, review)?.transcriptText == transcript.text, keep ? "Keep lost the transcript" : "Use the Other Copy erased the transcript")
    #expect(store.meeting(id: review)?.transcriptText == transcript.text)
    #expect(onDisk(root, third) != nil, "an answer overwrote the other copy's meeting")
}

/// The same without a banner: a transcript whose save loses to the other copy is made again to the
/// re-read copy and saved, rather than raising a banner that offers it as the person's change.
@MainActor
@Test("A result whose save loses with no banner up is saved onto the re-read copy without asking (F662)")
func aResultThatLosesWithNoOfferIsSavedWithoutAsking() throws {
    let (model, root, cleanup) = try makeModel()
    defer { cleanup() }
    let store = model.store
    let review = UUID()
    store.upsert(MeetingRecord(id: review, title: "Review", status: .processing))
    try otherCopyCommits(in: root) { $0.map { var r = $0; r.title = "Review, renamed by the other copy"; return r } }

    model.apply(result: transcript, to: review)

    #expect(store.conflictOffer == nil, "a result was offered as a question: \(store.conflictOffer?.message ?? "")")
    #expect(store.writeConflict == nil)
    let saved = try #require(onDisk(root, review))
    #expect(saved.title == "Review, renamed by the other copy", "the other copy's rename was overwritten")
    #expect(saved.transcriptText == transcript.text, "the transcript was not saved onto the re-read copy")
    #expect(saved.status == .completed)
}

/// Follow-up B of the lane-Q review: a result's mutation runs on two copies while the banner is up —
/// the list's (the other copy's version) and the offered one (this window's). Cancellation and failure
/// decided "does it still hold a transcript?" from the list's copy and wrote that answer into both, so
/// when the two disagreed Keep saved `.failed` and an error over a transcript the person had kept.
/// Each copy is now judged by itself.
@MainActor
@Test("A transcription failing while the banner is up judges each copy by its own transcript (F662)")
func failureWhileAnOfferIsUpJudgesEachCopyByItself() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F662-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = testSuiteName()
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    let model = AppModel(
        store: MeetingStore(rootDirectory: root, transcriptWriteDebounce: 60), recorder: AudioCaptureEngine(),
        defaults: defaults, whisperExecutable: { URL(fileURLWithPath: "/usr/bin/true") }, qwenInstalled: { true }
    )
    struct EngineFailed: Error {}
    model.runTranscriptionEngineOverride = { _, _ in throw EngineFailed() }
    let store = model.store
    let id = UUID()
    store.upsert(MeetingRecord(id: id, title: "Standup", recordingPath: "none", status: .recorded))
    // This window types a transcript; the other copy renames the meeting first, so the typing is
    // offered back — the offered copy holds a transcript, the list's copy does not.
    try otherCopyCommits(in: root) { $0.map { var r = $0; r.title = renamedThere; return r } }
    store.editTranscript(id: id, text: "What I typed while it was recorded.")
    store.flushPendingEdits()
    let offer = try #require(store.conflictOffer, "fixture: the typed transcript lost and was offered back")
    try #require(offer.delta.first { $0.id == id }?.transcriptText == "What I typed while it was recorded.")
    try #require(store.meeting(id: id)?.transcriptText.isEmpty == true)

    model.beginTranscription(id: id)
    let deadline = Date().addingTimeInterval(30)
    while model.hasActiveTranscription || model.hasQueuedTranscriptions || store.meeting(id: id)?.status == .processing,
          Date() < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(store.meeting(id: id)?.status == .failed, "fixture: the run failed and the list's copy, with no transcript, says so")

    let kept = try #require(store.conflictOffer?.delta.first { $0.id == id })
    #expect(kept.status == .completed, "the copy holding a transcript was marked \(kept.status) from the other copy's")
    #expect(kept.errorMessage == nil, "the copy holding a transcript was given the failure as if it had none")
    store.keepConflictedEdit()
    let saved = try #require(onDisk(root, id))
    #expect(saved.transcriptText == "What I typed while it was recorded.")
    #expect(saved.status == .completed, "Keep saved a kept transcript as \(saved.status)")
}

/// The behavioural tests above drive three of the app's result writers. The rest — an import, a
/// transcription's status, its cancellation and its failure, a rebuilt recording — are pinned here on
/// source, comments stripped (F285): every meeting write in each of these functions is a `.result`,
/// so a new write added to one of them without it fails here rather than being dropped while a
/// banner is up.
@Test("Every meeting write in the app's result paths is marked a result (F662)")
func resultWritersAreMarkedOnSource() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppModel.swift")
    let functions = [
        "func stopRecording(title: String",
        "func adoptImportedRecording(",
        "func performSummarization(",
        "private func performTranscription(id: UUID)",
        "private func apply(progress: LocalTranscriptionProgress",
        "result: TranscriptionResult, to id: UUID",
        "private func handleCancellation(id: UUID)",
        "private func handle(error: Error, id: UUID)",
        "private func applySourceRebuild(",
    ]
    for anchor in functions {
        let start = try #require(source.range(of: anchor), "\(anchor) is gone; update this list")
        let end = source[start.upperBound...].range(of: "func ")?.lowerBound ?? source.endIndex
        let body = source[start.upperBound..<end]
        let writes = body.components(separatedBy: "store.update(").count - 1
            + body.components(separatedBy: "store.upsert(").count - 1
        let results = body.components(separatedBy: "as: .result)").count - 1
        #expect(writes > 0, "\(anchor) no longer writes a meeting; update this list")
        #expect(results == writes, "\(anchor): \(writes) meeting write(s), \(results) marked .result")
    }
}

/// The person's own edits are still held back while the banner is up (F619): one shown here would be
/// made to the other copy's version of a meeting the banner may be about, and Keep would then put the
/// older copy back over it.
@MainActor
@Test("The person's own edits are still refused while the banner is up (F619, F662)")
func editsAreStillRefusedWhileAnOfferIsUp() throws {
    let (model, root, cleanup) = try makeModel()
    defer { cleanup() }
    let store = model.store
    let id = UUID(), other = UUID()
    store.upsert(MeetingRecord(id: id, title: "Standup", status: .completed))
    store.upsert(MeetingRecord(id: other, title: "Review", status: .completed))
    try raiseOffer(on: store, root: root, id: id)
    let attempts = store.persistCount

    store.update(id: other) { $0.title = "Review, renamed while the banner is up" }
    model.addMarker(to: other, offset: 1)

    #expect(store.persistCount == attempts)
    #expect(store.meeting(id: other)?.title == "Review")
    #expect(store.meeting(id: other)?.markers == nil)
    #expect(store.conflictOffer != nil)
}
