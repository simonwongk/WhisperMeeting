import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F666 — `deleteMeetings(ids:)` stopped every job of every REQUESTED meeting before asking the store
// to delete anything, and discarded the store's answer. A delete the store refused or lost — a
// recording folder that could not be removed (F146), a save another running copy beat (F642) —
// left the meeting in the library with its running transcription, summary or second opinion thrown
// away, and a cancelled transcription was then saved onto it as "Local transcription was cancelled".
//
// Each refused-delete test holds a job at a gate, makes the delete fail, then opens the gate and
// requires the job's own result to land. The standing-delete guard requires that stopping only the
// meetings that are gone still stops the ones removed. The last three are a lost race whose re-read
// no longer lists the meeting: its jobs stop when the other copy had deleted it too, and keep running
// when the conflict offer can bring the row back.

/// A job held open until released. Whether it was cancelled is recorded, so "the job finished" and
/// "the job was stopped" cannot be mistaken for each other.
private final class GatedProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _started = false
    private var _released = false
    private var _cancelled = false
    var started: Bool { lock.withLock { _started } }
    var cancelled: Bool { lock.withLock { _cancelled } }
    func release() { lock.withLock { _released = true } }

    struct NeverReleased: Error {}

    /// Waits for `release()` in small steps, for at most ~10 s. `Task.sleep` throws on cancellation,
    /// which is how the real subprocess clients report it.
    func run() async throws {
        lock.withLock { _started = true }
        do {
            for _ in 0..<5_000 {
                if lock.withLock({ _released }) { return }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
        } catch {
            lock.withLock { _cancelled = true }
            throw error
        }
        throw NeverReleased()
    }
}

/// The polled value is each caller's own subject; an exhausted budget fails as the wait it is.
@MainActor
private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    var ticks = 0
    while !condition(), ticks < 6_000 {
        try await Task.sleep(nanoseconds: 5_000_000)
        ticks += 1
    }
    try #require(condition(), "timed out waiting for \(what)")
}

private struct GatedSummarizer: MeetingSummarizer {
    let probe: GatedProbe
    func summarize(transcript: String, language: String?, style: SummaryStyle, template: MeetingTemplate) async throws -> MeetingSummary {
        try await probe.run()
        return MeetingSummary(summary: "the summary this meeting asked for", keyPoints: [], actionItems: [])
    }
}

private struct FolderStuck: Error {}

private let cancelledMessage = "Local transcription was cancelled. The recording is unchanged."

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

/// A library with one meeting per status on a real 16-bit mono WAV under `Recordings/<id>`, so the
/// delete has a folder of the meeting's own to remove.
@MainActor
private func makeModel(_ statuses: [MeetingStatus]) throws -> (AppModel, URL, [UUID]) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F666-\(UUID().uuidString)")
    let defaults = try #require(UserDefaults(suiteName: "F666.\(UUID().uuidString)"))
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults,
                         whisperExecutable: { URL(fileURLWithPath: "/usr/bin/true") }, qwenInstalled: { true })
    var ids: [UUID] = []
    for (index, status) in statuses.enumerated() {
        let id = UUID()
        let directory = root.appendingPathComponent("Recordings/\(id.uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sampleRate: UInt32 = 16_000
        let bytes = sampleRate * 2 * 2
        var wav = WAVWriter.header(sampleRate: sampleRate, dataByteCount: bytes)
        wav.append(Data(count: Int(bytes)))
        try wav.write(to: directory.appendingPathComponent("meeting.wav"))
        let segments = status == .completed ? [seg("An existing transcript line.", 0, 1)] : []
        model.store.upsert(MeetingRecord(
            id: id, title: "Synthetic \(index)", duration: 2,
            recordingPath: "Recordings/\(id.uuidString)/meeting.wav", status: status,
            transcriptText: TranscriptFormatter.timestamped(segments), segments: segments
        ))
        ids.append(id)
    }
    return (model, root, ids)
}

@MainActor
private func gateEngine(_ model: AppModel, _ probe: GatedProbe) {
    model.runTranscriptionEngineOverride = { _, _ in
        try await probe.run()
        return TranscriptionResult(id: "stub", text: "The transcript the job produced.", languageCode: "en",
                                   audioDuration: 1, confidence: nil,
                                   segments: [seg("The transcript the job produced.", 0, 1)])
    }
}

/// Another copy of the app committing over the same files, having read what is there — so this
/// session's next save loses the race (the `foreignWriterCommits` shape F433's and F642's tests use).
@MainActor
private func foreignWriterRetitles(in root: URL) throws {
    let rival = BackupJSONStore<[MeetingRecord]>(
        primaryURL: root.appendingPathComponent("meetings.json"),
        backupURL: root.appendingPathComponent("meetings.backup.json"),
        writer: "ffff9999",
        recordCount: { $0.count }
    )
    let existing = try #require(try rival.load())
    var records = existing.value
    for index in records.indices { records[index].title += ", retitled by the other copy" }
    _ = try rival.save(records, expecting: existing.token)
}

/// The same rival committing `change` over what it has just read. Called from a
/// `removeRecordingDirectory` stub, it lands between a kept-folder delete's two saves, as the rival
/// in F642's `lostRestoringSaveOffersTheKeptRowBack` does.
private func foreignWriterCommits(in root: URL, _ change: ([MeetingRecord]) -> [MeetingRecord]) throws {
    let rival = BackupJSONStore<[MeetingRecord]>(
        primaryURL: root.appendingPathComponent("meetings.json"),
        backupURL: root.appendingPathComponent("meetings.backup.json"),
        writer: "ffff9999",
        recordCount: { $0.count }
    )
    let existing = try rival.load()
    _ = try rival.save(change(existing?.value ?? []), expecting: existing?.token)
}

@MainActor
@Test("A delete whose folder cannot be removed leaves the meeting's summary and second opinion running (F666)")
func keptFolderDeleteLeavesSummaryAndSecondOpinionRunning() async throws {
    let (model, _, ids) = try makeModel([.completed])
    let id = ids[0]
    let summaryProbe = GatedProbe()
    let engineProbe = GatedProbe()
    model.summarizationEngine = .local
    model.isSummarizerModelInstalled = { true }
    model.makeSummarizer = { _, _ in GatedSummarizer(probe: summaryProbe) }
    gateEngine(model, engineProbe)
    model.summarize(id: id)
    #expect(model.requestSecondOpinion(id: id))
    try await waitUntil("both jobs to start") { summaryProbe.started && engineProbe.started }

    model.store.removeRecordingDirectory = { _ in throw FolderStuck() }
    model.deleteMeetings(ids: [id])
    try #require(model.store.meeting(id: id) != nil, "the delete was meant to be refused, and it went through")

    summaryProbe.release()
    engineProbe.release()
    try await waitUntil("both jobs to end") { model.activeSummarizationID == nil && !model.isRunningAuxiliaryEngine }

    #expect(!summaryProbe.cancelled, "a delete that did not happen stopped the meeting's summary")
    #expect(!engineProbe.cancelled, "a delete that did not happen stopped the meeting's second opinion")
    #expect(model.store.meeting(id: id)?.summary?.summary == "the summary this meeting asked for")
    #expect(model.secondOpinionSpans != nil, "the second opinion's result was thrown away")
}

@MainActor
@Test("A delete whose folder cannot be removed leaves the meeting's transcription running (F666)")
func keptFolderDeleteLeavesTranscriptionRunning() async throws {
    let (model, _, ids) = try makeModel([.recorded])
    let id = ids[0]
    let probe = GatedProbe()
    gateEngine(model, probe)
    model.beginTranscription(id: id)
    try await waitUntil("the transcription to start") { probe.started }

    model.store.removeRecordingDirectory = { _ in throw FolderStuck() }
    model.deleteMeetings(ids: [id])
    try #require(model.store.meeting(id: id) != nil, "the delete was meant to be refused, and it went through")

    probe.release()
    try await waitUntil("the transcription to end") { !model.hasActiveTranscription }

    #expect(!probe.cancelled, "a delete that did not happen stopped the meeting's transcription")
    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.errorMessage != cancelledMessage, "a meeting that was never deleted was told it was cancelled")
    #expect(meeting.status == .completed)
    #expect(meeting.transcriptText.contains("The transcript the job produced."))
}

@MainActor
@Test("A delete lost to another running copy leaves the meeting's transcription running (F666)")
func lostRaceDeleteLeavesTranscriptionRunning() async throws {
    let (model, root, ids) = try makeModel([.recorded])
    let id = ids[0]
    let probe = GatedProbe()
    gateEngine(model, probe)
    model.beginTranscription(id: id)
    try await waitUntil("the transcription to start") { probe.started }

    try foreignWriterRetitles(in: root)
    model.deleteMeetings(ids: [id])
    try #require(model.store.meeting(id: id) != nil, "the delete was meant to lose the race, and it went through")

    probe.release()
    try await waitUntil("the transcription to end") { !model.hasActiveTranscription }

    #expect(!probe.cancelled, "a delete that did not happen stopped the meeting's transcription")
    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.errorMessage != cancelledMessage, "a meeting that was never deleted was told it was cancelled")
    #expect(meeting.status == .completed)
    #expect(meeting.transcriptText.contains("The transcript the job produced."))
}

// The guard on the reorder: stopping only what was removed must still stop what WAS removed — the
// running job and a queued one. F441 Part 2 notes the older delete-transcription test could not
// fail; this one requires both states before the delete.
@MainActor
@Test("A delete that stands still stops the running transcription and drops the queued one (F666)")
func standingDeleteStopsRunningAndQueuedTranscriptions() async throws {
    let (model, _, ids) = try makeModel([.recorded, .recorded])
    let (running, queued) = (ids[0], ids[1])
    let probe = GatedProbe()
    gateEngine(model, probe)
    model.beginTranscription(id: running)
    try await waitUntil("the first transcription to start") { probe.started }
    model.beginTranscription(id: queued)
    try #require(model.isQueuedForTranscription(queued), "the second meeting never queued")

    model.deleteMeetings(ids: ids)
    try #require(model.store.meeting(id: running) == nil && model.store.meeting(id: queued) == nil,
                 "the delete was meant to stand")
    #expect(!model.isQueuedForTranscription(queued), "a deleted meeting is still waiting to be transcribed")
    try await waitUntil("the running transcription to end") { !model.hasActiveTranscription }

    #expect(probe.cancelled, "the deleted meeting's transcription was not stopped")
    #expect(!model.hasQueuedTranscriptions)
}

// A lost race re-reads the library. When the other copy had deleted the same meeting, it is gone
// from this one too, and so is its detail view, which holds every Cancel for its jobs. So its jobs
// must stop as a standing delete's do, although `store.delete` reports nothing removed. The first
// cut of F666 stopped only the ids `store.delete` returns, and left this job running (found by the
// lane's independent review, as a probe).
@MainActor
@Test("A delete lost to another running copy that had deleted the same meeting still stops its transcription (F666)")
func lostRaceToACopyThatAlsoDeletedItStopsTheTranscription() async throws {
    let (model, root, ids) = try makeModel([.recorded, .recorded])
    let (doomed, survivor) = (ids[0], ids[1])
    let probe = GatedProbe()
    gateEngine(model, probe)
    model.beginTranscription(id: doomed)
    try await waitUntil("the transcription to start") { probe.started }

    try foreignWriterCommits(in: root) { $0.filter { $0.id != doomed } }
    model.deleteMeetings(ids: [doomed])
    try #require(!model.store.isDegraded, "the re-read was meant to leave a writable library")
    try #require(model.store.meeting(id: doomed) == nil, "the re-read was meant to show the other copy's delete")
    try #require(model.store.meeting(id: survivor) != nil)
    let offeredBack = model.store.conflictOffer?.delta.map(\.id) ?? []
    try #require(!offeredBack.contains(doomed), "the row was offered back, which is lostRestoringSaveLeavesTheOfferedRowsTranscriptionRunning's case")

    // Never released: the job ends by being stopped, or when the probe gives up on its own.
    try await waitUntil("the transcription to end") { !model.hasActiveTranscription }
    #expect(probe.cancelled, "the meeting is gone from the library, and its transcription was not stopped")
}

// The summary is stopped in the same loop as the transcription, and the second opinion by the
// auxiliary checks below it. Both must read the same set.
@MainActor
@Test("A delete lost to another running copy that had deleted the same meeting still stops its summary and second opinion (F666)")
func lostRaceToACopyThatAlsoDeletedItStopsTheSummaryAndSecondOpinion() async throws {
    let (model, root, ids) = try makeModel([.completed, .completed])
    let (doomed, survivor) = (ids[0], ids[1])
    let summaryProbe = GatedProbe()
    let engineProbe = GatedProbe()
    model.summarizationEngine = .local
    model.isSummarizerModelInstalled = { true }
    model.makeSummarizer = { _, _ in GatedSummarizer(probe: summaryProbe) }
    gateEngine(model, engineProbe)
    model.summarize(id: doomed)
    #expect(model.requestSecondOpinion(id: doomed))
    try await waitUntil("both jobs to start") { summaryProbe.started && engineProbe.started }

    try foreignWriterCommits(in: root) { $0.filter { $0.id != doomed } }
    model.deleteMeetings(ids: [doomed])
    try #require(!model.store.isDegraded, "the re-read was meant to leave a writable library")
    try #require(model.store.meeting(id: doomed) == nil, "the re-read was meant to show the other copy's delete")
    try #require(model.store.meeting(id: survivor) != nil)
    let offeredBack = model.store.conflictOffer?.delta.map(\.id) ?? []
    try #require(!offeredBack.contains(doomed), "the row was offered back, which is lostRestoringSaveLeavesTheOfferedRowsTranscriptionRunning's case")

    // Never released, as above.
    try await waitUntil("both jobs to end") { model.activeSummarizationID == nil && !model.isRunningAuxiliaryEngine }
    #expect(summaryProbe.cancelled, "the meeting is gone from the library, and its summary was not stopped")
    #expect(engineProbe.cancelled, "the meeting is gone from the library, and its second opinion was not stopped")
}

// The exception, and why it exists. A delete whose folder cannot be removed saves twice: once without
// the row, then again to put it back (F146). When another copy saves between the two, the re-read
// puts the row back and saves it once more (F642, F667) — and when the other copy saves AGAIN before
// that, the row is left unlisted and held by the offer, which saves it whichever answer is given. So
// "no longer listed" alone would stop the job of a row that either answer lists again.
@MainActor
@Test("A kept-folder delete whose save putting the row back lost a race leaves the offered row's transcription running (F666)")
func lostRestoringSaveLeavesTheOfferedRowsTranscriptionRunning() async throws {
    let (model, root, ids) = try makeModel([.recorded])
    let id = ids[0]
    let probe = GatedProbe()
    gateEngine(model, probe)
    model.beginTranscription(id: id)
    try await waitUntil("the transcription to start") { probe.started }

    let theirs = MeetingRecord(id: UUID(), title: "The other copy's meeting", recordingPath: "none", status: .recorded)
    let alsoTheirs = MeetingRecord(id: UUID(), title: "The other copy's second meeting", recordingPath: "none", status: .recorded)
    model.store.removeRecordingDirectory = { _ in
        try foreignWriterCommits(in: root) { $0 + [theirs] }
        throw FolderStuck()
    }
    // The saves inside this one delete: without the row, putting it back (lost to `theirs`), then
    // the recovery's own save of the row — lost too, to the other copy's second commit (F667).
    var saves = 0
    model.store.beforeIndexSaveForTesting = {
        saves += 1
        if saves == 3 { try? foreignWriterCommits(in: root) { $0 + [alsoTheirs] } }
    }
    model.deleteMeetings(ids: [id])
    model.store.beforeIndexSaveForTesting = nil
    try #require(saves == 3, "fixture: the recovery's save of the kept row was meant to run")
    try #require(model.store.meeting(id: id) == nil, "the second lost save was meant to leave the kept row unlisted")
    let offeredBack = model.store.conflictOffer?.unsavedNew.map(\.id) ?? []
    let expected: [UUID] = [id]
    try #require(offeredBack == expected, "the kept row was meant to be held by the offer")

    model.store.keepConflictedEdit()
    try #require(model.store.meeting(id: id) != nil, "Keep My Edit did not list the row again")
    probe.release()
    try await waitUntil("the transcription to end") { !model.hasActiveTranscription }

    #expect(!probe.cancelled, "the transcription of a row the offer could bring back was stopped")
    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.errorMessage != cancelledMessage, "a row brought back by Keep My Edit was told it was cancelled")
    #expect(meeting.status == .completed)
    #expect(meeting.transcriptText.contains("The transcript the job produced."))
}
