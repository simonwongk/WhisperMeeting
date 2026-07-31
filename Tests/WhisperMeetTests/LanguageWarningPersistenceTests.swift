import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F32 — the "original language only" guard must reach the user. The reachable hop is
// AppModel.apply(result:to:requestedLanguage:), which stores LanguageConsistency.mismatchWarning
// onto the MeetingRecord so MeetingDetailView can render it. These tests drive that app-level call
// over a temp store; the SwiftUI advisory has no view harness and is verified manually (F32 log).

@MainActor
private func headyModel() -> AppModel {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LanguageWarningPersistenceTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(
        at: root.appendingPathComponent("Recordings", isDirectory: true),
        withIntermediateDirectories: true
    )
    let suite = "WhisperMeet.LanguageWarningPersistenceTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
}

private func result(id: UUID, text: String) -> TranscriptionResult {
    TranscriptionResult(
        id: id.uuidString, text: text, languageCode: nil, audioDuration: 1,
        confidence: nil, segments: [], alignmentWarning: nil
    )
}

/// A Mandarin meeting transcribed under an explicit English selection comes back English text; the
/// mismatch must land on the stored meeting. Fails before F32 wired the guard through apply.
@MainActor
@Test("A wrong-language transcript persists a language warning through the app-level apply (F32)")
func languageMismatchReachesStoredMeeting() {
    let model = headyModel()
    let id = UUID()
    model.store.upsert(MeetingRecord(id: id, title: "Meeting", status: .processing))

    model.apply(result: result(id: id, text: "Can you send the report by Friday?"),
                to: id, requestedLanguage: .chinese)

    #expect(model.store.meeting(id: id)?.languageWarning != nil)
}

/// A transcript matching the selected language, and any automatic-mode run, leave the field nil.
@MainActor
@Test("A matching language and automatic selection leave the language warning nil (F32)")
func matchingAndAutomaticLeaveNoWarning() {
    let model = headyModel()

    let matchID = UUID()
    model.store.upsert(MeetingRecord(id: matchID, title: "Match", status: .processing))
    model.apply(result: result(id: matchID, text: "帮我把今天的会议纪要发给团队。"),
                to: matchID, requestedLanguage: .chinese)
    #expect(model.store.meeting(id: matchID)?.languageWarning == nil)

    let autoID = UUID()
    model.store.upsert(MeetingRecord(id: autoID, title: "Auto", status: .processing))
    model.apply(result: result(id: autoID, text: "Send the report by Friday."),
                to: autoID, requestedLanguage: .automatic)
    #expect(model.store.meeting(id: autoID)?.languageWarning == nil)
}
