import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F220 — the review surface's state machine and its precomputed row labels, at the AppModel layer.
// Genuinely red against the current tree: `AppModel.speakerReviewState(for:)`,
// `AppModel.speakerRowLabels(for:)` and `AppModel.speakerOverlayRevision` do not exist, so this file
// does not compile.
//
// They live here rather than in the SwiftUI body for two reasons. The `WhisperMeet` target has no
// view-render harness and never will (`AGENTS.md` "Wiring an unreachable core", layer 3), so an `if`
// inside a banner is a rule no test can reach. And the row labels MUST be precomputed off the render
// path: `PlayableTranscriptView` redraws on the 4 Hz playback tick, and a per-row overlay lookup
// there is the exact regression F160 already documents — so the map is built by one app-level call
// and the view only reads it.

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

private final class Gate: @unchecked Sendable {
    var started = false
    var release = false
}

private func writeSilentWav(seconds: Double, to url: URL) throws {
    let sampleRate: UInt32 = 16_000
    let dataBytes = UInt32(seconds * Double(sampleRate)) * 2
    var wav = WAVWriter.header(sampleRate: sampleRate, dataByteCount: dataBytes)
    wav.append(Data(count: Int(dataBytes)))
    try wav.write(to: url)
}

@MainActor
private struct ReviewFixture {
    let model: AppModel
    let id: UUID
    let root: URL
    var meeting: MeetingRecord { model.store.meeting(id: id)! }
    var sidecar: URL { DiarizationArtifactStore.fileURL(meetingID: id, in: root) }
}

@MainActor
private func makeReviewFixture(
    segments: [TranscriptSegment] = [seg("one", 0, 4), seg("two", 4, 8)]
) throws -> ReviewFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiarizationReview-\(UUID().uuidString)", isDirectory: true)
    let id = UUID()
    let directory = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try writeSilentWav(seconds: 8, to: directory.appendingPathComponent("meeting.wav"))

    let seed = MeetingStore(rootDirectory: root)
    seed.upsert(MeetingRecord(
        id: id, title: "M", duration: 8,
        recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed,
        transcriptText: TranscriptFormatter.timestamped(segments),
        segments: segments
    ))
    try #require(!seed.isDegraded, "the seed store must be writable, or nothing was persisted")

    let defaults = UserDefaults(suiteName: "F220review.\(UUID().uuidString)")!
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    model.isDiarizationModelInstalled = { true }
    model.refreshRuntime()
    return ReviewFixture(model: model, id: id, root: root)
}

private func result(_ turns: [SpeakerTurn], speakers: Int) -> SpeakerDiarizationResult {
    SpeakerDiarizationResult(turns: turns, speakerCount: speakers, audioSeconds: 8)
}

private func turn(_ start: Double, _ end: Double, _ cluster: Int) -> SpeakerTurn {
    SpeakerTurn(startSeconds: start, endSeconds: end, clusterID: cluster, kind: .speech)
}

@MainActor
private func spin(_ label: String, until condition: @MainActor () -> Bool) async {
    var ticks = 0
    while !condition(), ticks < 200_000 {
        await Task.yield()
        ticks += 1
    }
    #expect(condition(), "timed out waiting for \(label)")
}

@MainActor
private func analyze(_ fixture: ReviewFixture, _ turns: [SpeakerTurn], speakers: Int) async {
    fixture.model.runSpeakerDiarization = { _, _ in result(turns, speakers: speakers) }
    fixture.model.requestSpeakerDiarization(for: fixture.id)
    await spin("the analysis to finish") { fixture.model.diarizationRunningID == nil }
}

@MainActor
@Test("A meeting that was never analyzed shows no review banner at all (F220)")
func reviewStateIsNotAnalyzedBeforeAnyRun() throws {
    let fixture = try makeReviewFixture()
    #expect(fixture.model.speakerReviewState(for: fixture.id) == .notAnalyzed)
    #expect(fixture.model.speakerRowLabels(for: fixture.id).isEmpty)
}

@MainActor
@Test("Two distinguished voices produce a labeled state and one precomputed label per segment (F220)")
func reviewStateIsLabeledForTwoVoices() async throws {
    let fixture = try makeReviewFixture()
    await analyze(fixture, [turn(0, 4, 0), turn(4, 8, 1)], speakers: 2)

    #expect(fixture.model.speakerReviewState(for: fixture.id) == .labeled)
    let labels = fixture.model.speakerRowLabels(for: fixture.id)
    #expect(labels == [0: "Speaker 1", 1: "Speaker 2"])

    // A rename is visible through the same precomputed map — the view never looks an alias up per row.
    fixture.model.renameSpeaker(clusterID: 1, to: "Nadia", in: fixture.id)
    #expect(fixture.model.speakerRowLabels(for: fixture.id) == [0: "Speaker 1", 1: "Nadia"])
}

@MainActor
@Test("One distinguished voice suppresses every label and says so as a normal outcome (F220)")
func reviewStateIsSingleVoiceForOneCluster() async throws {
    let fixture = try makeReviewFixture()
    await analyze(fixture, [turn(0, 4, 0), turn(4, 8, 0)], speakers: 1)

    #expect(fixture.model.speakerReviewState(for: fixture.id) == .singleVoice)
    #expect(fixture.model.speakerRowLabels(for: fixture.id).isEmpty)
}

@MainActor
@Test("An analysis that found no speech reports no turns rather than one voice (F220)")
func reviewStateIsNoTurnsFoundForAnEmptyResult() async throws {
    let fixture = try makeReviewFixture()
    await analyze(fixture, [], speakers: 0)

    // Distinct from `.singleVoice`: nothing was told apart because nothing was found, and the
    // single-voice wording ("a single speaker") would be a claim about a recording with no speech.
    #expect(fixture.model.speakerReviewState(for: fixture.id) == .noTurnsFound)
    #expect(fixture.model.speakerRowLabels(for: fixture.id).isEmpty)
}

@MainActor
@Test("Voices told apart but never attributable to a line report that, not one voice (F220)")
func reviewStateIsNoConfidentLabelsWhenTheOverlayAbstains() async throws {
    let fixture = try makeReviewFixture()
    // Two clusters, split evenly inside each segment: the overlay's coverage floor and margin both
    // fail, so every row is uncertain and no cluster is shown. Saying "only one voice" here would be
    // false — two were told apart.
    await analyze(fixture, [turn(0, 2, 0), turn(2, 4, 1), turn(4, 6, 0), turn(6, 8, 1)], speakers: 2)

    #expect(fixture.model.speakerReviewState(for: fixture.id) == .noConfidentLabels)
    #expect(fixture.model.speakerRowLabels(for: fixture.id).isEmpty)
}

@MainActor
@Test("Re-timed segments make a stored analysis stale, and the labels are withheld (F220)")
func reviewStateIsStaleAfterTheTimingsChange() async throws {
    let fixture = try makeReviewFixture()
    await analyze(fixture, [turn(0, 4, 0), turn(4, 8, 1)], speakers: 2)
    try #require(fixture.model.speakerReviewState(for: fixture.id) == .labeled)

    var meeting = fixture.meeting
    meeting.segments = [seg("one", 0, 5), seg("two", 5, 8)]
    fixture.model.store.upsert(meeting)

    #expect(fixture.model.speakerReviewState(for: fixture.id) == .stale)
    #expect(fixture.model.speakerRowLabels(for: fixture.id).isEmpty)
    // The result itself is KEPT — a stale overlay is hidden, never deleted behind the user's back.
    #expect(FileManager.default.fileExists(atPath: fixture.sidecar.path))
}

@MainActor
@Test("A damaged sidecar is reported as unreadable, not as a meeting that was never analyzed (F220)")
func reviewStateIsUnreadableForADamagedSidecar() throws {
    let fixture = try makeReviewFixture()
    // The two outcomes offer opposite next steps — "analyze this meeting" versus "your labels are
    // gone and here is why" — so collapsing them into one silent banner-less state is the bug.
    try Data("{ this is not an artifact".utf8).write(to: fixture.sidecar)

    #expect(fixture.model.speakerReviewState(for: fixture.id) == .unreadable)
    #expect(fixture.model.speakerRowLabels(for: fixture.id).isEmpty)
}

@MainActor
@Test("A run in flight reports analyzing, and cancelling returns to the previous state (F220)")
func reviewStateIsAnalyzingWhileTheRuntimeWorks() async throws {
    let fixture = try makeReviewFixture()
    let gate = Gate()
    fixture.model.runSpeakerDiarization = { _, _ in
        gate.started = true
        while !gate.release { await Task.yield() }
        try Task.checkCancellation()
        return result([turn(0, 4, 0), turn(4, 8, 1)], speakers: 2)
    }
    fixture.model.requestSpeakerDiarization(for: fixture.id)
    await spin("the seam to start") { gate.started }

    #expect(fixture.model.speakerReviewState(for: fixture.id) == .analyzing)

    fixture.model.cancelSpeakerDiarization()
    gate.release = true
    await spin("the analysis to stop") { fixture.model.diarizationRunningID == nil }
    // Cancel writes nothing, so the meeting is exactly where it started.
    #expect(fixture.model.speakerReviewState(for: fixture.id) == .notAnalyzed)
    #expect(!FileManager.default.fileExists(atPath: fixture.sidecar.path))
}

@MainActor
@Test("Every change to the stored analysis bumps a revision the transcript view can watch (F220)")
func speakerOverlayRevisionMovesOnEveryStoredChange() async throws {
    let fixture = try makeReviewFixture()
    let atStart = fixture.model.speakerOverlayRevision

    await analyze(fixture, [turn(0, 4, 0), turn(4, 8, 1)], speakers: 2)
    let afterAnalysis = fixture.model.speakerOverlayRevision
    #expect(afterAnalysis > atStart, "a finished analysis did not invalidate the precomputed labels")

    fixture.model.renameSpeaker(clusterID: 0, to: "Ada", in: fixture.id)
    let afterRename = fixture.model.speakerOverlayRevision
    #expect(afterRename > afterAnalysis, "a rename did not invalidate the precomputed labels")

    fixture.model.clearSpeakerDiarization(for: fixture.id)
    #expect(fixture.model.speakerOverlayRevision > afterRename, "clearing did not invalidate them")
    #expect(fixture.model.speakerReviewState(for: fixture.id) == .notAnalyzed)
}

// F339 — the ≥2-cluster gate counted clusters *after* F317's sub-second suppression had already
// turned rows `.uncertain`. In a two-cluster meeting where one participant's every confidently
// covered row happens to be under a second — a quiet participant, or a rapid exchange — that
// cluster disappeared from the count, the gate fell to one cluster, and every row in the meeting
// was rewritten to `.unlabeled`: including the long, 99.8%-correct ones. The same meeting was fully
// labelled before F317.

@MainActor
@Test("A cluster whose rows are all sub-second does not strip the meeting's other labels (F339)")
func subSecondClusterDoesNotStripTheMeeting() async throws {
    let fixture = try makeReviewFixture(segments: [
        seg("a long turn", 0, 4),
        seg("another long turn", 4, 7.4),
        seg("mm", 7.5, 7.9)          // 0.4 s — under F317's one-second floor
    ])
    await analyze(fixture, [turn(0, 7.4, 0), turn(7.5, 7.9, 1)], speakers: 2)

    let presentation = try #require(fixture.model.speakerOverlay(for: fixture.id))
    #expect(!presentation.isSingleCluster, "the analysis distinguished two voices; the display rule hid one")
    #expect(presentation.distinguishedVoiceCount == 2)
    let labels = fixture.model.speakerRowLabels(for: fixture.id)
    #expect(labels[0] == "Speaker 1")
    #expect(labels[1] == "Speaker 1")
    #expect(labels[2] == SpeakerOverlay.uncertainName, "the short row itself is still not named (F317)")
    #expect(fixture.model.speakerReviewState(for: fixture.id) == .labeled)
}

@MainActor
@Test("A meeting the analysis really found one voice in is still reported as one voice (F339)")
func genuinelySingleClusterIsStillSingle() async throws {
    let fixture = try makeReviewFixture(segments: [seg("one", 0, 4), seg("two", 4, 8)])
    await analyze(fixture, [turn(0, 8, 0)], speakers: 1)

    let presentation = try #require(fixture.model.speakerOverlay(for: fixture.id))
    #expect(presentation.isSingleCluster)
    #expect(fixture.model.speakerRowLabels(for: fixture.id).isEmpty)
}
