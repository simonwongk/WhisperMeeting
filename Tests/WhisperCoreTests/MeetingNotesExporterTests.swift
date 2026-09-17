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

@Test("Marker context is dropped once the transcript has been edited")
func markerContextDroppedWhenEdited() {
    let segments = [TranscriptSegment(speaker: nil, start: 0, end: 5, text: "the plan")]
    let markers = [RecordingMarker(id: UUID(), offset: 2, label: "Decision")]
    let canonical = TranscriptFormatter.timestamped(segments)

    // Unedited transcript: the marker gets its segment as context.
    let unedited = MeetingNotesExporter.markdown(
        title: "M", dateText: "", durationSeconds: 0, languageCode: nil, summary: nil,
        transcriptText: canonical, markers: markers, segments: segments)
    #expect(unedited.contains("— the plan"))

    // Edited transcript: segment-derived context would contradict the edited body, so it's omitted
    // (the marker line still appears, just without a stale context clause).
    let edited = MeetingNotesExporter.markdown(
        title: "M", dateText: "", durationSeconds: 0, languageCode: nil, summary: nil,
        transcriptText: "an entirely rewritten transcript", markers: markers, segments: segments)
    #expect(edited.contains("## Markers"))
    #expect(edited.contains("Decision"))
    #expect(!edited.contains("— the plan"))
}

@Test("Meeting notes export includes a Notes section only when notes are present")
func exportsNotesSection() {
    let withNotes = MeetingNotesExporter.markdown(
        title: "Weekly Sync",
        dateText: "",
        durationSeconds: 0,
        languageCode: nil,
        summary: nil,
        transcriptText: "Hello.",
        notes: "Agenda: budget, hiring"
    )
    #expect(withNotes.contains("## Notes"))
    #expect(withNotes.contains("Agenda: budget, hiring"))
    // Notes appear above the transcript.
    let notesIndex = withNotes.range(of: "## Notes")!.lowerBound
    let transcriptIndex = withNotes.range(of: "## Transcript")!.lowerBound
    #expect(notesIndex < transcriptIndex)

    let withoutNotes = MeetingNotesExporter.markdown(
        title: "Weekly Sync",
        dateText: "",
        durationSeconds: 0,
        languageCode: nil,
        summary: nil,
        transcriptText: "Hello.",
        notes: "   "
    )
    #expect(!withoutNotes.contains("## Notes"))
}

@Test("Meeting notes emit a confidence section only for a scored, unedited transcript")
func exportsConfidenceSection() {
    let segments = [
        TranscriptSegment(speaker: nil, start: 0, end: 2, text: "clean one", avgLogprob: -0.3, noSpeechProb: 0.01, compressionRatio: 1.2),
        TranscriptSegment(speaker: nil, start: 62, end: 64, text: "clean two", avgLogprob: -0.4, noSpeechProb: 0.02, compressionRatio: 1.3),
        TranscriptSegment(speaker: nil, start: 125, end: 127, text: "shaky", avgLogprob: -2.0, noSpeechProb: 0.05, compressionRatio: 1.4),
    ]
    let transcriptText = TranscriptFormatter.timestamped(segments)

    let md = MeetingNotesExporter.markdown(
        title: "t", dateText: "", durationSeconds: 0, languageCode: nil,
        summary: nil, transcriptText: transcriptText, segments: segments
    )
    #expect(md.contains("## Confidence"))
    #expect(md.contains("67% clean"))                 // 3 scored, 1 flagged → 2/3
    #expect(md.contains("1 of 3 segments flagged"))
    #expect(md.contains("02:05"))                     // the flagged segment at 125s

    // An edited transcript emits no confidence section.
    let editedMd = MeetingNotesExporter.markdown(
        title: "t", dateText: "", durationSeconds: 0, languageCode: nil,
        summary: nil, transcriptText: "totally different edited text", segments: segments
    )
    #expect(!editedMd.contains("## Confidence"))

    // An unscored transcript (no segments) emits no confidence section.
    let unscoredMd = MeetingNotesExporter.markdown(
        title: "t", dateText: "", durationSeconds: 0, languageCode: nil,
        summary: nil, transcriptText: "some text", segments: []
    )
    #expect(!unscoredMd.contains("## Confidence"))
}

// MARK: - F281: caveats about the recording itself

@Test("A recovery warning appears above everything it qualifies")
func caveatsPrecedeTheContentTheyQualify() {
    // The placement IS the feature. A caveat under the transcript is a footnote; the point is that
    // the reader must know the audio is incomplete before they trust the text, not after.
    let markdown = MeetingNotesExporter.markdown(
        title: "Pricing sync",
        dateText: "Sep 17, 2026 at 9:00 AM",
        durationSeconds: 750,
        languageCode: "en",
        summary: nil,
        transcriptText: "We agreed on the tiering.",
        caveats: ["The rebuilt audio stops at 12:30 because a source track could not be read past that point."]
    )
    let caveats = try! #require(markdown.range(of: "## About this recording"))
    let transcript = try! #require(markdown.range(of: "## Transcript"))
    #expect(caveats.lowerBound < transcript.lowerBound)
    #expect(markdown.contains("- The rebuilt audio stops at 12:30"))
}

@Test("A meeting with nothing to caveat gets no section and no empty heading")
func noCaveatsMeansNoSection() {
    // The counterpart that keeps the section meaningful: an empty "About this recording" under
    // every clean meeting would train the reader to skip it.
    let markdown = MeetingNotesExporter.markdown(
        title: "Clean",
        dateText: "Sep 17, 2026 at 9:00 AM",
        durationSeconds: 600,
        languageCode: "en",
        summary: nil,
        transcriptText: "All good."
    )
    #expect(!markdown.contains("About this recording"))
}

@Test("Several caveats share one section, in the order given")
func caveatsShareOneSection() {
    let markdown = MeetingNotesExporter.markdown(
        title: "Messy",
        dateText: "Sep 17, 2026 at 9:00 AM",
        durationSeconds: 60,
        languageCode: "en",
        summary: nil,
        transcriptText: "Text.",
        caveats: ["Audio is short.", "Timestamps were unavailable.", "Language looks wrong."]
    )
    #expect(markdown.components(separatedBy: "## About this recording").count == 2)
    let short = try! #require(markdown.range(of: "- Audio is short."))
    let stamps = try! #require(markdown.range(of: "- Timestamps were unavailable."))
    let language = try! #require(markdown.range(of: "- Language looks wrong."))
    #expect(short.lowerBound < stamps.lowerBound)
    #expect(stamps.lowerBound < language.lowerBound)
}

@Test("A blank caveat is dropped rather than rendered as an empty bullet")
func blankCaveatsAreDropped() {
    let markdown = MeetingNotesExporter.markdown(
        title: "Edge",
        dateText: "Sep 17, 2026 at 9:00 AM",
        durationSeconds: 60,
        languageCode: "en",
        summary: nil,
        transcriptText: "Text.",
        caveats: ["  ", "", "Real one."]
    )
    #expect(markdown.contains("- Real one."))
    #expect(!markdown.contains("- \n"))
    #expect(markdown.components(separatedBy: "\n- ").count == 2)
}
