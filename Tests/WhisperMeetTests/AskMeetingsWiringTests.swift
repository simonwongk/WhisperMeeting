import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F180 — the AppModel adapter gathers in-scope meetings from the store (completed + tag filter) and
// returns cited retrieval results. The ranking/scope logic itself is covered by WhisperCore tests.

@MainActor
private func makeModel() throws -> AppModel {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AskMeetingsWiringTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: "F180.\(UUID().uuidString)")!
    return AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
}

private func seg(_ start: Double, _ text: String) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: start + 5, text: text)
}

@MainActor
@Test("askMeetings scopes by tag + completed status and returns cited, timestamped results (F180)")
func askMeetingsScopesAndCites() throws {
    let model = try makeModel()

    let a = UUID(), b = UUID(), c = UUID()
    model.store.upsert(MeetingRecord(
        id: a, title: "Pricing sync", status: .completed,
        segments: [seg(0, "We discussed the pricing discount tiers."), seg(30, "Marketing owns the update.")],
        tags: ["pricing"]
    ))
    // Same keyword, different tag — excluded by the tag scope.
    model.store.upsert(MeetingRecord(
        id: b, title: "Hiring", status: .completed,
        segments: [seg(0, "Pricing was mentioned once.")],
        tags: ["hiring"]
    ))
    // Matches the tag but isn't completed — excluded by status.
    model.store.upsert(MeetingRecord(
        id: c, title: "Draft", status: .recorded,
        segments: [seg(0, "Pricing pricing pricing.")],
        tags: ["pricing"]
    ))

    let scoped = model.askMeetings(query: "pricing discount", scope: MeetingScope(tags: ["pricing"]))
    #expect(!scoped.isEmpty)
    #expect(scoped.allSatisfy { $0.meetingID == a })
    let top = try #require(scoped.first)
    #expect(top.timestamp == 0)
    #expect(top.snippet.contains("pricing"))

    // Empty scope = all completed meetings (A and B), never the non-completed C.
    let all = model.askMeetings(query: "pricing", scope: MeetingScope())
    let ids = Set(all.map(\.meetingID))
    #expect(ids.contains(a))
    #expect(ids.contains(b))
    #expect(!ids.contains(c))
}
