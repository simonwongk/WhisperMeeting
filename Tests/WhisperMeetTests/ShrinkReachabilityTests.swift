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

@Test("The meeting page writes Shrink's refusal under the button, not only as a tooltip (F800)")
func shrinkRefusalIsWrittenUnderTheButton() throws {
    // `docs/MEETING_STORAGE_DESIGN.md` (Refusals): disabled with the reason underneath, the
    // `speakerAnalysisUnavailability` pattern. The Storage sheet did; the page gave only `.help`,
    // which nobody had shown to appear on a disabled button. Whichever of the plan's sentences
    // applies is shown — the Wave 6 "shrinking it isn't available yet" among them — because the
    // sentence is `MeetingStoragePlan.Unavailability.message`, the same property the sheet shows.
    let content = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let header = try #require(content.range(of: "private func header(_ meeting: MeetingRecord) -> some View {"))
    let headerEnd = try #require(content.range(of: "private func ", range: header.upperBound..<content.endIndex))
    let body = content[header.upperBound..<headerEnd.lowerBound]
    #expect(body.contains("let shrinkReason = model.shrinkUnavailability(for: meeting)"))
    #expect(body.contains("Button(\"Shrink…\") { model.requestShrink(ids: [meeting.id]) }"))
    #expect(body.contains("Text(shrinkReason.message)"), "the reason is a tooltip only: \(body)")
    // Already shrunk shows no button and no reason, as before.
    #expect(body.contains("shrinkReason != .alreadyShrunk"))
    let sheet = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/MeetingStorageView.swift")
    #expect(sheet.contains("Text(reason.message)"), "the sheet and the page show the same sentence")
}

@Test("The transcript player reloads when a shrink changes the recording's path (F795)")
func shrinkReloadsThePlayer() throws {
    let content = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(content.contains(".id([meetingID.uuidString, meeting.recordingPath])"))
}
