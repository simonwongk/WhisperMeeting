import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F740 — a link import's captions (`MeetingRecord.referenceSegments`, stored since F183) reach a
// read-only comparison through `AppModel.compareWithCaptions`, the call the Improve menu's
// "Compare with the Video's Captions…" makes. The user chose read-only (2026-10-17): nothing copies
// caption text into the transcript, so these also hold that the meeting is unchanged afterwards.

private func seg(_ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

private let lines = [
    seg(0, 4, "We agreed to ship on Friday."),
    seg(4, 8, "Dana will email Acme about pricing."),
    seg(30, 34, "Thanks, everyone."),
]

private let captions = [
    seg(0, 4, "we agreed to ship on friday"),
    seg(4, 8, "dana will email acne about pricing"),
]

@MainActor
private func makeModel() throws -> (AppModel, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F740-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    return (model, root)
}

/// What a link import whose page published captions stores (`adoptImportedRecording`).
@MainActor
private func upsertLinkImport(_ model: AppModel, referenceSegments: [TranscriptSegment]?) -> UUID {
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "Launch review", status: .completed,
        transcriptText: TranscriptFormatter.timestamped(lines), segments: lines,
        source: MediaSource(kind: MediaSource.youTubeKind, pageURL: "https://example.com/v", host: "example.com",
                            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)),
        referenceSegments: referenceSegments
    ))
    return id
}

private actor Inputs {
    var transcript: [TranscriptSegment] = []
    var captions: [TranscriptSegment] = []
    var onMainThread = true
    func record(_ t: [TranscriptSegment], _ c: [TranscriptSegment], main: Bool) {
        transcript = t
        captions = c
        onMainThread = main
    }
}

@MainActor
@Test("A link import's captions reach the comparison, lined up against its transcript (F740)")
func captionsReachTheComparison() async throws {
    let (model, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = upsertLinkImport(model, referenceSegments: captions)
    try #require(AppModel.hasCaptions(try #require(model.store.meeting(id: id))))

    let outcome = await model.compareWithCaptions(id: id)

    guard case let .rows(rows) = outcome else {
        Issue.record("no comparison: \(outcome)")
        return
    }
    #expect(rows.map(\.kind) == [.same, .differs, .notInCaptions])
    try #require(rows.count == 3)
    #expect(rows[1].captionText == "dana will email acne about pricing")
}

@MainActor
@Test("The comparison is given the stored captions and the transcript as the user left it, off the main actor (F740)")
func theComparisonReadsTheEditedLinesAndTheCaptions() async throws {
    let (model, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = upsertLinkImport(model, referenceSegments: captions)
    try FileManager.default.createDirectory(at: model.store.recordingDirectoryURL(for: id), withIntermediateDirectories: true)
    // A hand edit deletes the Dana line (F455): the comparison must not show it.
    model.store.editTranscript(id: id, text: "00:00  We agreed to ship on Friday.\n00:30  Thanks, everyone.")
    let inputs = Inputs()
    model.compareCaptions = { transcript, captions in
        let main = Thread.isMainThread
        Task { await inputs.record(transcript, captions, main: main) }
        return CaptionComparison.compare(transcript: transcript, captions: captions)
    }

    let outcome = await model.compareWithCaptions(id: id)

    guard case let .rows(rows) = outcome else {
        Issue.record("no comparison: \(outcome)")
        return
    }
    #expect(rows.map(\.transcriptText) == ["We agreed to ship on Friday.", "Thanks, everyone."])
    let deadline = SuspendingClock.now + .seconds(30)
    while await inputs.captions.isEmpty, SuspendingClock.now < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
    #expect(await inputs.captions == captions)
    #expect(await inputs.transcript.map(\.text) == ["We agreed to ship on Friday.", "Thanks, everyone."])
    #expect(await inputs.onMainThread == false)
}

@MainActor
@Test("Comparing with the captions changes nothing in the meeting (F740)")
func comparingIsReadOnly() async throws {
    let (model, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = upsertLinkImport(model, referenceSegments: captions)
    let before = try #require(model.store.meeting(id: id))

    _ = await model.compareWithCaptions(id: id)

    #expect(model.store.meeting(id: id) == before)
}

@MainActor
@Test("A meeting without captions says why there is nothing to compare (F740)")
func noCaptionsIsSaid() async throws {
    let (model, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = upsertLinkImport(model, referenceSegments: nil)
    #expect(!AppModel.hasCaptions(try #require(model.store.meeting(id: id))))
    #expect(await model.compareWithCaptions(id: id) == .unavailable(AppModel.captionComparisonNoCaptionsMessage))
}

/// The brace-balanced body after the first `marker`.
private func body(following marker: String, in source: String) throws -> Substring {
    let start = try #require(source.range(of: marker), "\(marker) is gone from ContentView.swift")
    let open = try #require(source.range(of: "{", range: start.upperBound..<source.endIndex))
    var depth = 1
    var cursor = open.upperBound
    while cursor < source.endIndex, depth > 0 {
        if source[cursor] == "{" { depth += 1 } else if source[cursor] == "}" { depth -= 1 }
        cursor = source.index(after: cursor)
    }
    return source[open.upperBound..<cursor]
}

@Test("The Improve menu offers the captions comparison, and its sheet can write nothing (F740)")
func theMenuOffersAReadOnlyComparison() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(source.contains("Compare with the Video's Captions"))
    #expect(source.contains("model.compareWithCaptions(id: meetingID)"))
    #expect(source.contains("AppModel.hasCaptions(meeting)"))
    // Brace-walked with literals blanked, so a `{` in a string is not a scope.
    let structure = SourceAssertion.stripComments(
        try String(contentsOf: SourceAssertion.url("Sources/WhisperMeet/ContentView.swift"), encoding: .utf8),
        blankStringLiterals: true
    )
    let sheet = try body(following: "private struct CaptionComparisonSheet", in: structure)
    // Read-only: the sheet is handed no model and no store, and calls nothing that writes.
    for writer in ["model.", "store.", "onReplace", "applySecondOpinionSpan", "@ObservedObject", "@EnvironmentObject"] {
        #expect(!sheet.contains(writer), "the captions sheet reaches \(writer)")
    }
}
