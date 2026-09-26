import Foundation
import Testing
@testable import WhisperCore

// F524 — README's disk-space table understated recording growth by about 19x: a flat "48 kHz mono
// audio ≈ 1 GB per ~11 hours" (≈ 0.09 GB/hour) against the real combined write rate of meeting.wav
// plus both raw float32 source tracks (≈ 1.7 GB/hour). Derived here from RecordingSizeEstimator —
// the same arithmetic AudioCaptureEngine and RecordingHealthMonitor already use — rather than a
// hand-picked number, so a future capture-format change (a different sample rate, say) makes this
// test fail instead of letting the prose quietly go stale again.

@Test("README's recording disk-space figure matches RecordingSizeEstimator's derived rate (F524)")
func readmeDiskFigureMatchesTheEstimator() throws {
    let readme = try String(contentsOf: SourceAssertion.url("README.md"), encoding: .utf8)

    let workingBytesPerHour = RecordingSizeEstimator.workingBytes(
        forDuration: 3_600,
        sampleRate: RecordingSizeEstimator.defaultSampleRate
    )
    let gigabytesPerHour = Double(workingBytesPerHour) / 1_000_000_000
    // Rounded to one decimal, matching the precision the prose actually states.
    let rounded = (gigabytesPerHour * 10).rounded() / 10
    let statedRate = "≈ \(String(format: "%.1f", rounded)) GB per recorded hour"

    #expect(readme.contains(statedRate), """
        README's disk-space table must state the CURRENT combined write rate (meeting.wav plus both \
        raw source tracks), derived here as \(statedRate) from RecordingSizeEstimator. If \
        AudioCaptureEngine's capture format ever changes, update the README's own sentence — this \
        failure is the signal, not a hand-recomputed guess.
        """)

    // The two components the sentence breaks the rate into, so a reader can sanity-check the sum
    // rather than trust one opaque number.
    let mixedGigabytesPerHour = Double(
        RecordingSizeEstimator.mixedBytes(forDuration: 3_600, sampleRate: RecordingSizeEstimator.defaultSampleRate)
    ) / 1_000_000_000
    let mixedRounded = (mixedGigabytesPerHour * 100).rounded() / 100
    #expect(readme.contains("`meeting.wav` (48 kHz, 16-bit mono) ≈ \(String(format: "%.2f", mixedRounded)) GB"))

    let sourceGigabytesPerHourPerTrack = Double(
        RecordingSizeEstimator.sourceBytesPerSecond(sampleRate: RecordingSizeEstimator.defaultSampleRate)
    ) * 3_600 / 1_000_000_000 / 2
    let sourceRounded = (sourceGigabytesPerHourPerTrack * 100).rounded() / 100
    #expect(readme.contains("≈ \(String(format: "%.2f", sourceRounded)) GB each"))
}
