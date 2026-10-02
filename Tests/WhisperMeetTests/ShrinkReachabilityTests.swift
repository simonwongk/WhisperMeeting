import Foundation
import Testing
@testable import WhisperMeet

// F795 — the target cannot render views (F174), so reachability is asserted on the source, with
// comments stripped so a sentence about the button cannot satisfy it (F285).

@Test("The meeting page and Settings reach Shrink and its gate (F795)")
func shrinkIsReachableFromTheInterface() throws {
    let content = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(content.contains("model.requestShrink(ids:"))
    #expect(content.contains("model.performShrink(confirmed: true)"))
    #expect(content.contains("model.shrinkUnavailability(for:"))
    #expect(content.contains("model.storageBytes(for:"))
    #expect(content.contains("model.refreshStorage(ids:"))
    #expect(content.contains("MeetingStorageView("))
    // The page's dialog stands down while the Storage sheet shows its own.
    #expect(content.contains("!model.isStorageSheetOpen"))
    let sheet = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/MeetingStorageView.swift")
    #expect(sheet.contains("model.requestShrink(ids:"))
    #expect(sheet.contains("model.performShrink(confirmed: true)"))
    #expect(sheet.contains("model.refreshStorage(ids:"))
    #expect(sheet.contains("model.isStorageSheetOpen = true"))
}

@Test("The transcript player reloads when a shrink changes the recording's path (F795)")
func shrinkReloadsThePlayer() throws {
    let content = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(content.contains(".id([meetingID.uuidString, meeting.recordingPath])"))
}
