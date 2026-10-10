import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F82 — the GlossaryCorrector core (delivers F65) shipped tested but unreachable. Wiring adds two
// AppModel methods so the meeting-detail transcript toolbar can compute proposals and apply the
// user-accepted ones. This drives the app-level calls over a temp store and asserts the transcript
// is corrected while the recording is never touched.
@MainActor
@Test("Glossary corrections compute and apply through AppModel without touching audio (F82)")
func glossaryCorrectionsApplyThroughAppModel() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("GlossaryWiringTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Recordings", isDirectory: true),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = UserDefaults(suiteName: testSuiteName())!
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)

    let segments = [
        TranscriptSegment(speaker: nil, start: 0, end: 1, text: "we deployed cooper netties today"),
        TranscriptSegment(speaker: nil, start: 1, end: 2, text: "and it worked"),
    ]
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id,
        title: "M",
        recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed,
        transcriptText: TranscriptFormatter.timestamped(segments),
        segments: segments
    ))
    model.store.addVocabulary(["Kubernetes"])

    // F536: the pass is asynchronous now, off the main actor.
    let proposals = try #require(await model.proposeGlossaryCorrections(for: id))
    #expect(proposals.contains { $0.to == "Kubernetes" && $0.segmentIndex == 0 })

    model.applyGlossaryCorrections(proposals, to: id)
    let updated = model.store.meeting(id: id)
    #expect(updated?.segments[0].text.contains("Kubernetes") == true)
    #expect(updated?.segments[1].text == "and it worked")   // untouched
    #expect(updated?.transcriptText == TranscriptFormatter.timestamped(updated!.segments))

    // A text-only correction never creates or opens the recording.
    #expect(!FileManager.default.fileExists(atPath: model.store.recordingURL(for: updated!).path))
}

@MainActor
@Test("Correct Toward Vocabulary keeps the comma after the word it corrects (F819)")
func glossaryCorrectionKeepsPunctuationThroughAppModel() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("GlossaryWiringTests-F819-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    let segments = [TranscriptSegment(speaker: nil, start: 0, end: 1, text: "Ship the Kestrol, then tell Priya.")]
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "M", status: .completed,
        transcriptText: TranscriptFormatter.timestamped(segments), segments: segments
    ))
    model.store.addVocabulary(["Kestrel"])

    let proposals = try #require(await model.proposeGlossaryCorrections(for: id))
    #expect(proposals == [GlossaryCorrection(segmentIndex: 0, from: "Kestrol", to: "Kestrel")])

    model.applyGlossaryCorrections(proposals, to: id)
    #expect(model.store.meeting(id: id)?.segments.first?.text == "Ship the Kestrel, then tell Priya.")
}

@MainActor
@Test("Correct Toward Vocabulary proposes nothing for a two-word name already spelled right (F820)")
func glossaryCorrectionLeavesACorrectTwoWordTermAlone() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("GlossaryWiringTests-F820-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    let segments = [
        TranscriptSegment(speaker: nil, start: 0, end: 1, text: "Priya Raman said the release is ready."),
        TranscriptSegment(speaker: nil, start: 1, end: 2, text: "Ask Priya Ramen about it."),
    ]
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "M", status: .completed,
        transcriptText: TranscriptFormatter.timestamped(segments), segments: segments
    ))
    model.store.addVocabulary(["Priya Raman"])

    let proposals = try #require(await model.proposeGlossaryCorrections(for: id))
    // Only the real mishearing, on the second line.
    #expect(proposals == [GlossaryCorrection(segmentIndex: 1, from: "Priya Ramen", to: "Priya Raman")])
}

@MainActor
@Test("Correct Toward Vocabulary offers no row that applying would leave unchanged, such as a correct four-word name (F820)")
func glossaryCorrectionOffersNoRowThatChangesNothing() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("GlossaryWiringTests-F820-noop-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    let segments = [
        TranscriptSegment(speaker: nil, start: 0, end: 1, text: "The Bank of New York said yes."),
        TranscriptSegment(speaker: nil, start: 1, end: 2, text: "We deployed cooper\tnetties today."),
    ]
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "M", status: .completed,
        transcriptText: TranscriptFormatter.timestamped(segments), segments: segments
    ))
    model.store.addVocabulary(["Bank of New York", "Kubernetes"])

    let proposals = try #require(await model.proposeGlossaryCorrections(for: id))
    #expect(proposals.isEmpty)
}
