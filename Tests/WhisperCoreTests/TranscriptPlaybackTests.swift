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

@Test("An open-ended final segment stops at the recording duration")
func boundsOpenEndedFinalSegment() {
    let openEnded = [
        TranscriptSegment(speaker: nil, start: 2, end: nil, text: "final"),
    ]

    #expect(TranscriptPlayback.activeIndex(at: 4, in: openEnded, recordingDuration: 5) == 0)
    #expect(TranscriptPlayback.activeIndex(at: 5, in: openEnded, recordingDuration: 5) == nil)
    #expect(TranscriptPlayback.activeIndex(at: 100, in: openEnded, recordingDuration: 5) == nil)
}
