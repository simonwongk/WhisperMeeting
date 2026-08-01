import Testing
@testable import WhisperMeet

@Test("Dictation pill level buckets exactly match the number of rendered bars (F120)")
func dictationPillBucketsMatchRenderedBars() {
    let cases: [(level: Float, expectedBars: Int)] = [
        (-0.1, 0),
        (0, 0),
        (0.01, 1),
        (0.2, 1),
        (0.21, 2),
        (0.4, 2),
        (0.41, 3),
        (0.6, 3),
        (0.61, 4),
        (0.8, 4),
        (0.81, 5),
        (1, 5),
        (1.1, 5),
    ]

    for item in cases {
        #expect(
            DictationPillLevelBucket.bucket(for: item.level) == item.expectedBars,
            "level \(item.level) should render \(item.expectedBars) bars"
        )
    }
}
