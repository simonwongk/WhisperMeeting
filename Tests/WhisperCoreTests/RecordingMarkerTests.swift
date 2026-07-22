import Foundation
import Testing
@testable import WhisperCore

private func marker(_ offset: TimeInterval, _ label: String? = nil, id: UUID = UUID()) -> RecordingMarker {
    RecordingMarker(id: id, offset: offset, label: label)
}

@Test("Inserting keeps markers sorted by offset")
func insertingSorts() {
    var markers: [RecordingMarker] = []
    markers = RecordingMarkers.inserting(marker(30), into: markers)
    markers = RecordingMarkers.inserting(marker(10), into: markers)
    markers = RecordingMarkers.inserting(marker(20), into: markers)
    #expect(markers.map(\.offset) == [10, 20, 30])
}

@Test("A negative offset is clamped to zero")
func insertingClampsNegative() {
    let markers = RecordingMarkers.inserting(marker(-5), into: [])
    #expect(markers.first?.offset == 0)
}

@Test("displayLabel uses the custom label when present, else a 1-based fallback")
func displayLabelFallback() {
    #expect(RecordingMarkers.displayLabel(for: marker(10, "Decision"), at: 1) == "Decision")
    #expect(RecordingMarkers.displayLabel(for: marker(10), at: 3) == "Marker 3")
    // A blank/whitespace label falls back too.
    #expect(RecordingMarkers.displayLabel(for: marker(10, "   "), at: 2) == "Marker 2")
}

@Test("segmentText returns the segment whose range contains the offset")
func segmentTextWithinRange() {
    let segments = [
        TranscriptSegment(speaker: nil, start: 0, end: 5, text: "intro"),
        TranscriptSegment(speaker: nil, start: 5, end: 10, text: "the decision"),
        TranscriptSegment(speaker: nil, start: 10, end: 15, text: "wrap up")
    ]
    #expect(RecordingMarkers.segmentText(at: 7, in: segments) == "the decision")
}

@Test("segmentText falls back to the last segment starting before the offset")
func segmentTextBeforeOffset() {
    let segments = [
        TranscriptSegment(speaker: nil, start: 0, end: 5, text: "intro"),
        TranscriptSegment(speaker: nil, start: 5, end: 8, text: "middle")
    ]
    // Offset 12 is past every segment end → the last segment that started before it.
    #expect(RecordingMarkers.segmentText(at: 12, in: segments) == "middle")
}

@Test("segmentText is nil when no segment starts before the offset or none exist")
func segmentTextNil() {
    let segments = [TranscriptSegment(speaker: nil, start: 10, end: 15, text: "later")]
    #expect(RecordingMarkers.segmentText(at: 3, in: segments) == nil)
    #expect(RecordingMarkers.segmentText(at: 5, in: []) == nil)
}

@Test("The markdown section lists markers with timestamps, labels, and context")
func markdownSection() {
    let segments = [
        TranscriptSegment(speaker: nil, start: 0, end: 60, text: "opening remarks"),
        TranscriptSegment(speaker: nil, start: 60, end: 120, text: "we agreed to ship Friday")
    ]
    let markers = [marker(75, "Decision"), marker(10)]
    let section = RecordingMarkers.markdownSection(markers: markers, segments: segments)
    #expect(section == """
    ## Markers

    - **00:10** Marker 1 — opening remarks
    - **01:15** Decision — we agreed to ship Friday
    """)
}

@Test("The markdown section is empty when there are no markers")
func markdownSectionEmpty() {
    #expect(RecordingMarkers.markdownSection(markers: [], segments: []).isEmpty)
}

@Test("A marker without transcript context omits the context clause")
func markdownSectionNoContext() {
    let section = RecordingMarkers.markdownSection(markers: [marker(30)], segments: [])
    #expect(section == """
    ## Markers

    - **00:30** Marker 1
    """)
}

@Test("RecordingMarker survives a Codable round-trip")
func markerCodable() throws {
    let original = marker(42.5, "Key point", id: UUID())
    let data = try JSONEncoder().encode(original)
    let restored = try JSONDecoder().decode(RecordingMarker.self, from: data)
    #expect(restored == original)
}

@Test("Meeting notes include a Markers section between summary and transcript")
func notesIncludeMarkers() {
    let notes = MeetingNotesExporter.markdown(
        title: "Sync",
        dateText: "Jul 22, 2026",
        durationSeconds: 130,
        languageCode: "en",
        summary: nil,
        transcriptText: "00:10  hello",
        markers: [marker(65, "Decision")],
        segments: [TranscriptSegment(speaker: nil, start: 60, end: 120, text: "ship Friday")]
    )
    #expect(notes.contains("## Markers"))
    #expect(notes.contains("- **01:05** Decision — ship Friday"))
    // Order: Markers before Transcript.
    let markersRange = notes.range(of: "## Markers")!
    let transcriptRange = notes.range(of: "## Transcript")!
    #expect(markersRange.lowerBound < transcriptRange.lowerBound)
}

@Test("Meeting notes with no markers are unchanged (no empty Markers heading)")
func notesWithoutMarkers() {
    let notes = MeetingNotesExporter.markdown(
        title: "Sync",
        dateText: "",
        durationSeconds: 0,
        languageCode: nil,
        summary: nil,
        transcriptText: "hello"
    )
    #expect(!notes.contains("## Markers"))
}
