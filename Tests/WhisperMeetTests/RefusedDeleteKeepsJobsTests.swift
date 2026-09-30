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
// requires the job's own result to land. The last test is the standing-delete guard: stopping only
// the meetings that were removed must still stop them.

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
