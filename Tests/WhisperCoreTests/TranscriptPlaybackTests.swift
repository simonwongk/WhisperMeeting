import Testing
@testable import WhisperCore

private let segments = [
    TranscriptSegment(speaker: nil, start: 0.0, end: 2.0, text: "one"),
    TranscriptSegment(speaker: nil, start: 2.0, end: 5.0, text: "two"),
    TranscriptSegment(speaker: nil, start: 5.0, end: 9.0, text: "three"),
]

@Test("Active segment contains the current playback time")
func findsActiveSegment() {
    #expect(TranscriptPlayback.activeIndex(at: 0.0, in: segments) == 0)
    #expect(TranscriptPlayback.activeIndex(at: 1.9, in: segments) == 0)
    #expect(TranscriptPlayback.activeIndex(at: 2.0, in: segments) == 1)
    #expect(TranscriptPlayback.activeIndex(at: 7.5, in: segments) == 2)
    #expect(TranscriptPlayback.activeIndex(at: 100, in: segments) == nil)
}

@Test("No segment is highlighted during silence between transcript segments")
func noneDuringSegmentGap() {
    let separated = [
        TranscriptSegment(speaker: nil, start: 0, end: 2, text: "first"),
        TranscriptSegment(speaker: nil, start: 4, end: 6, text: "second"),
    ]

    #expect(TranscriptPlayback.activeIndex(at: 3, in: separated) == nil)
    #expect(TranscriptPlayback.activeIndex(at: 6, in: separated) == nil)
}

@Test("No segment is active before the first one begins")
func noneBeforeStart() {
    let later = [TranscriptSegment(speaker: nil, start: 3.0, end: 4.0, text: "late")]
    #expect(TranscriptPlayback.activeIndex(at: 1.0, in: later) == nil)
    #expect(TranscriptPlayback.activeIndex(at: 0.0, in: []) == nil)
}

@Test("An open-ended middle segment ends where the next segment starts")
func openEndedMiddleSegmentEndsAtNextStart() {
    let mixed = [
        TranscriptSegment(speaker: nil, start: 0, end: nil, text: "a"),
        TranscriptSegment(speaker: nil, start: 3, end: 5, text: "b"),
    ]
    #expect(TranscriptPlayback.activeIndex(at: 1, in: mixed) == 0)
    #expect(TranscriptPlayback.activeIndex(at: 2.9, in: mixed) == 0)
    #expect(TranscriptPlayback.activeIndex(at: 3, in: mixed) == 1)
}

@Test("With overlapping ranges the latest matching segment wins")
func overlappingLatestWins() {
    let overlapping = [
        TranscriptSegment(speaker: nil, start: 0, end: 5, text: "a"),
        TranscriptSegment(speaker: nil, start: 2, end: 8, text: "b"),
    ]
    #expect(TranscriptPlayback.activeIndex(at: 3, in: overlapping) == 1)
    #expect(TranscriptPlayback.activeIndex(at: 1, in: overlapping) == 0)
}

@Test("Active-index lookup stays correct across a large transcript")
func largeTranscriptCorrectness() {
    let many = (0..<5_000).map {
        TranscriptSegment(speaker: nil, start: Double($0), end: Double($0) + 1, text: "s\($0)")
    }
    #expect(TranscriptPlayback.activeIndex(at: 4_999.5, in: many) == 4_999)
    #expect(TranscriptPlayback.activeIndex(at: 0.5, in: many) == 0)
    #expect(TranscriptPlayback.activeIndex(at: 2_500.5, in: many) == 2_500)
}

@Test("An open-ended final segment stops at the recording duration")
func boundsOpenEndedFinalSegment() {
    let openEnded = [
        TranscriptSegment(speaker: nil, start: 2, end: nil, text: "final"),
    ]

    #expect(TranscriptPlayback.activeIndex(at: 4, in: openEnded, recordingDuration: 5) == 0)
    #expect(TranscriptPlayback.activeIndex(at: 5, in: openEnded, recordingDuration: 5) == nil)
    #expect(TranscriptPlayback.activeIndex(at: 100, in: openEnded, recordingDuration: 5) == nil)
}
