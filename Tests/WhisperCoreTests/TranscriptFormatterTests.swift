import Testing
@testable import WhisperCore

@Test("Segments render as one timestamped line each")
func timestampedRendersLines() {
    let segments = [
        TranscriptSegment(speaker: nil, start: 0, end: 2, text: "语言概念是有限的"),
        TranscriptSegment(speaker: nil, start: 2, end: 8, text: " 你比如说吧 "),
        TranscriptSegment(speaker: nil, start: 72, end: 75, text: "太极生两仪")
    ]
    #expect(TranscriptFormatter.timestamped(segments) == """
    00:00  语言概念是有限的
    00:02  你比如说吧
    01:12  太极生两仪
    """)
}

@Test("A segment without a start time renders as bare text")
func timestampedWithoutStart() {
    let segments = [TranscriptSegment(speaker: nil, start: nil, end: nil, text: "no clock")]
    #expect(TranscriptFormatter.timestamped(segments) == "no clock")
}

@Test("isTimestamped detects an MM:SS prefix on the first non-empty line")
func detectsTimestampedText() {
    #expect(TranscriptFormatter.isTimestamped("00:00  hello\n00:02  world"))
    #expect(TranscriptFormatter.isTimestamped("\n\n  01:12  later start"))
    #expect(!TranscriptFormatter.isTimestamped("just some plain text\nno stamps"))
    #expect(!TranscriptFormatter.isTimestamped(""))
}
