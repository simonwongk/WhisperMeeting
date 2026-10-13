import Foundation
import Testing
@testable import WhisperMeet

// F832 — `AppModel.transcribeAgainBlockedReason(for:)` returns a sentence (read-only library,
// already being transcribed, already queued), and `ContentView` used it only as `.disabled(… != nil)`
// on the Improve menu's "Transcribe Again…" and on the button beside the alignment notice. A greyed
// control that does not say why. The reason is now resolved once per control, shown as its help,
// and written out where a tooltip cannot be relied on: the Improve menu's footnotes, and a caption
// under the alignment notice. The views cannot be rendered here (F174), so this is pinned as source,
// comments stripped (F285).

@Test("Both Transcribe Again controls show the reason they are greyed, as help and in words (F832)")
func transcribeAgainControlsShowTheirReason() throws {
    let content = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    func count(_ needle: String) -> Int { content.components(separatedBy: needle).count - 1 }

    // Resolved once per control, so the grey and the sentence cannot disagree.
    #expect(count("let transcribeAgainReason = model.transcribeAgainBlockedReason(for: meetingID)") == 2)
    #expect(count(".disabled(model.transcribeAgainBlockedReason(for: meetingID) != nil)") == 0,
            "a control still greys itself without resolving the reason it could show")
    #expect(count(".disabled(transcribeAgainReason != nil)") == 2)
    #expect(count(".help(transcribeAgainReason ?? ") == 2)

    // The Improve menu's footnote block, where a menu row cannot be trusted to show help.
    let menu = try #require(content.range(of: "private func improveMenu(_ meeting: MeetingRecord) -> some View {"))
    let menuEnd = try #require(content.range(of: "private func ", range: menu.upperBound..<content.endIndex))
    let menuBody = content[menu.upperBound..<menuEnd.lowerBound]
    #expect(menuBody.contains("Text(transcribeAgainReason)"), "\(menuBody)")

    // The caption under the alignment notice, beside the button it explains (F306: beside, not inside).
    let notice = try #require(content.range(of: "if let warning = meeting.alignmentWarning {"))
    let noticeEnd = try #require(content.range(of: ".bannerSurface(.orange)", range: notice.upperBound..<content.endIndex))
    let noticeBody = content[notice.upperBound..<noticeEnd.lowerBound]
    #expect(noticeBody.contains("Button(\"Transcribe Again…\") { confirmTranscribeAgain = true }"))
    #expect(noticeBody.contains("Text(transcribeAgainReason)"), "\(noticeBody)")
}
