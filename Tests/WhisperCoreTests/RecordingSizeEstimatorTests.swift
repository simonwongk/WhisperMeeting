import Foundation
import Testing
@testable import WhisperCore

@Test("Mixed WAV size grows at 96 KB per second of recording")
func estimatesMixedRecordingSize() {
    // 48 kHz mono 16-bit = 96,000 bytes/sec.
    #expect(RecordingSizeEstimator.mixedBytesPerSecond() == 96_000)
    #expect(RecordingSizeEstimator.mixedBytes(forDuration: 0) == 0)
    #expect(RecordingSizeEstimator.mixedBytes(forDuration: 60) == 5_760_000)
    #expect(RecordingSizeEstimator.mixedBytes(forDuration: 3_600) == 345_600_000)
}

@Test("Working footprint includes both float32 source tracks")
func estimatesWorkingFootprint() {
    // Two float32 mono tracks = 384,000 bytes/sec, plus the 96,000 bytes/sec WAV = 480,000.
    #expect(RecordingSizeEstimator.sourceBytesPerSecond() == 384_000)
    #expect(RecordingSizeEstimator.workingBytes(forDuration: 60) == 28_800_000)
}

@Test("Negative or zero durations never produce negative sizes")
func clampsNonPositiveDurations() {
    #expect(RecordingSizeEstimator.mixedBytes(forDuration: -5) == 0)
    #expect(RecordingSizeEstimator.workingBytes(forDuration: -5) == 0)
}
