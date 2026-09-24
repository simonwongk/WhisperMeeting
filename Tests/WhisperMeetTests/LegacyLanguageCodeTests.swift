import Foundation
import Testing
@testable import WhisperMeet
@testable import WhisperCore

// F535 — a meeting an earlier build stored as "Chinese"/"English" must load as "zh"/"en".
//
// Before F535 a Whisper meeting transcribed under a pinned language stored the name openai-whisper
// echoes back, so `meetings.json` already holds "Chinese" and "English" in existing libraries. The
// sidebar's `lang:zh` / `lang:en` compare against the stored value and so never found those
// meetings, the header chip and exports printed "CHINESE", and `TranscriptLanguageFilter` fell back
// to counting lines. Fixing only what new transcriptions store would have left every one of them as
// it was. The store writes exactly what it is given, so an upsert of the old value reproduces the
// old file byte for byte.

@Test("A meeting stored as \"Chinese\" or \"English\" by an earlier build loads as its code (F535)")
@MainActor
func legacyLanguageNamesLoadAsCodes() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LegacyLanguageCode-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let chinese = UUID(), english = UUID(), detected = UUID(), unlabelled = UUID()
    let writer = MeetingStore(rootDirectory: root)
    writer.upsert(MeetingRecord(id: chinese, title: "Pinned Chinese", status: .completed, languageCode: "Chinese"))
    writer.upsert(MeetingRecord(id: english, title: "Pinned English", status: .completed, languageCode: "English"))
    writer.upsert(MeetingRecord(id: detected, title: "Detected", status: .completed, languageCode: "zh"))
    writer.upsert(MeetingRecord(id: unlabelled, title: "Not transcribed", status: .recorded))

    let reopened = MeetingStore(rootDirectory: root)
    #expect(reopened.meeting(id: chinese)?.languageCode == "zh")
    #expect(reopened.meeting(id: english)?.languageCode == "en")
    #expect(reopened.meeting(id: detected)?.languageCode == "zh")
    #expect(reopened.meeting(id: unlabelled)?.languageCode == nil)

    // The ticket's symptom, through the same facet the sidebar builds from a loaded meeting.
    let query = MeetingQuery.parse("lang:zh")
    let found = reopened.meetings.filter { meeting in
        query.matches(MeetingFacets(
            languageCode: meeting.languageCode,
            status: meeting.status.rawValue,
            durationSeconds: meeting.duration,
            createdAt: meeting.createdAt,
            textFields: [meeting.title]
        ))
    }
    #expect(Set(found.map(\.id)) == [chinese, detected])
}
