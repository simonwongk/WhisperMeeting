import Foundation
import Testing
@testable import WhisperCore

private func seg(_ start: TimeInterval, _ text: String) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: start + 1, text: text)
}

/// F60 — chapters partition the timeline by marker offsets.
@Test("Markers partition the timeline into chapters with correct ranges and segment assignment")
func chaptersPartitionByMarkers() {
    let markers = [
        RecordingMarker(offset: 0, label: "Intro"),
        RecordingMarker(offset: 300, label: "Demo"),
        RecordingMarker(offset: 750), // unlabeled → "Marker 3"
    ]
    let segments = [seg(10, "a"), seg(300, "b"), seg(800, "c")]

    let chapters = TranscriptChapters.chapters(markers: markers, segments: segments, durationSeconds: 1200)

    #expect(chapters.count == 3)
    #expect(chapters.map(\.title) == ["Intro", "Demo", "Marker 3"])
    #expect(chapters[0].start == 0 && chapters[0].end == 300)
    #expect(chapters[1].start == 300 && chapters[1].end == 750)
    #expect(chapters[2].start == 750 && chapters[2].end == 1200)
    #expect(chapters[0].segments.map(\.text) == ["a"])
    #expect(chapters[1].segments.map(\.text) == ["b"]) // boundary-start goes to the later chapter
    #expect(chapters[2].segments.map(\.text) == ["c"])
}

@Test("A leading chapter is prepended when the first marker starts after 0")
func chaptersLeadingChapter() {
    let chapters = TranscriptChapters.chapters(
        markers: [RecordingMarker(offset: 300, label: "Demo")],
        segments: [seg(10, "intro"), seg(400, "demo")],
        durationSeconds: 600
    )
    #expect(chapters.count == 2)
    #expect(chapters[0].title == TranscriptChapters.leadingTitle)
    #expect(chapters[0].start == 0 && chapters[0].end == 300)
    #expect(chapters[0].segments.map(\.text) == ["intro"])
}

@Test("No markers yields a single full-duration chapter")
func chaptersNoMarkers() {
    let chapters = TranscriptChapters.chapters(markers: [], segments: [seg(5, "x")], durationSeconds: 600)
    #expect(chapters.count == 1)
    #expect(chapters[0].start == 0 && chapters[0].end == 600)
    #expect(chapters[0].segments.map(\.text) == ["x"])
}
