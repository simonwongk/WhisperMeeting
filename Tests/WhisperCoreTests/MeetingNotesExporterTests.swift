import Foundation
import Testing
@testable import WhisperCore

@Test("Meeting notes combine metadata, summary, key points, action items, and transcript")
func exportsFullNotes() {
    let notes = MeetingNotesExporter.markdown(
        title: "Weekly Sync",
        dateText: "Aug 3, 2025 at 10:00 AM",
        durationSeconds: 3_725,
        languageCode: "en",
        summary: MeetingSummary(
            summary: "The team agreed on the Q3 plan.",
            keyPoints: ["Budget approved", "Launch in September"],
            actionItems: ["Alex drafts the spec"]
        ),
        transcriptText: "00:00  Hello.\n00:05  Let's begin."
    )

    #expect(notes.hasPrefix("# Weekly Sync\n"))
    #expect(notes.contains("_Aug 3, 2025 at 10:00 AM · 1:02:05 · EN_"))
    #expect(notes.contains("## Summary\n"))
    #expect(notes.contains("The team agreed on the Q3 plan."))
    #expect(notes.contains("### Key points\n- Budget approved\n- Launch in September"))
    #expect(notes.contains("### Action items\n- [ ] Alex drafts the spec"))
    #expect(notes.contains("## Transcript\n\n00:00  Hello.\n00:05  Let's begin."))
}

@Test("Without a summary, notes still export the transcript under its heading")
func exportsWithoutSummary() {
    let notes = MeetingNotesExporter.markdown(
        title: "Ad-hoc call",
        dateText: "",
        durationSeconds: 0,
        languageCode: nil,
        summary: nil,
        transcriptText: "Just some talk."
    )
    #expect(notes.hasPrefix("# Ad-hoc call\n"))
    #expect(!notes.contains("## Summary"))
    #expect(notes.contains("## Transcript\n\nJust some talk."))
}
