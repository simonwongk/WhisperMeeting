import Foundation
import Testing
@testable import WhisperCore

// F379 — the same number of clipped samples means different things depending on where they sit.
//
// F346 replaced "was clipping (too loud) at times" with a measured fraction of the whole
// recording, and that is right for the case it was filed about: 139 full-scale samples in 14.4
// million. It is the one place where the new sentence is *worse* than the one it replaced.
//
// Measured in the ticket: eight seconds of genuine +3 dB clipping inside a five-minute recording
// is 13,136 / 14,400,000 = 0.09%, which lands in the band that says "a small share of the
// recording". Eight seconds of flat-topped audio is not a small share of anything a listener
// cares about — it is a passage that is ruined, and the old sentence was actually correct for it.
//
// The fraction answers "how much of this recording clipped". The listener's question is closer to
// "is there a stretch I cannot use", and a global denominator cannot express that.

private let sampleRate = 48_000
private let fiveMinutes = sampleRate * 300

private func report(
    measured: Int,
    atFullScale: Int,
    worstSecond: ClippedSecond?
) -> RecordingHealthReport {
    RecordingHealthReport(
        warnings: [.systemAudioClipping],
        worstStatus: .caution,
        microphoneStaleSeconds: 0,
        systemAudioStaleSeconds: 0,
        systemAudioEverDetected: true,
        systemAudioFramesMeasured: measured,
        systemAudioFramesAtFullScale: atFullScale,
        systemAudioWorstSecond: worstSecond
    )
}

@Test("Concentrated and spread-out clipping of the same size read differently (F379)")
func concentratedClippingReadsDifferentlyFromSpread() throws {
    // The ticket's own numbers. 13,136 full-scale frames in a five-minute recording, twice:
    // once packed into eight seconds, once spread evenly across the whole thing.
    let total = 13_136

    // Packed: ~1,642 of each second's 48,000 frames, in eight seconds.
    let concentrated = try #require(RecordingHealthAdvisory.message(
        for: report(measured: fiveMinutes, atFullScale: total,
                    worstSecond: ClippedSecond(framesMeasured: sampleRate, framesAtFullScale: total / 8))
    ))
    // Spread: ~44 frames in every one of the 300 seconds, so the worst second IS the average.
    let spread = try #require(RecordingHealthAdvisory.message(
        for: report(measured: fiveMinutes, atFullScale: total,
                    worstSecond: ClippedSecond(framesMeasured: sampleRate, framesAtFullScale: total / 300))
    ))

    #expect(concentrated != spread, "the same count in two shapes must not read identically")
    #expect(concentrated.contains("concentrated in one stretch"), "\(concentrated)")
    #expect(!spread.contains("concentrated"), "\(spread)")
    // Both still carry the measured total — the locator is added to the evidence, never instead
    // of it. F346's rule stands: report the number, do not assert the verdict.
    #expect(concentrated.contains("13,136"))
    #expect(spread.contains("13,136"))
}

@Test("A worst second that is barely clipped says nothing extra (F379)")
func aBarelyClippedWorstSecondIsNotAnnounced() throws {
    // Three stray frames in a second is not a stretch anyone can hear, and announcing it would
    // make the clause meaningless in the common case — which is the failure mode of every
    // "highlight the peak" feature.
    let message = try #require(RecordingHealthAdvisory.message(
        for: report(measured: fiveMinutes, atFullScale: 139,
                    worstSecond: ClippedSecond(framesMeasured: sampleRate, framesAtFullScale: 3))
    ))
    #expect(!message.contains("concentrated"), "\(message)")
    #expect(message.contains("far too few to be a level problem"), "\(message)")
}

@Test("A recording that is clipped throughout does not call itself concentrated (F379)")
func uniformlyClippedAudioIsNotConcentrated() throws {
    // 20% everywhere: the worst second is heavily clipped AND matches the average, so the
    // ten-times test is what stops it claiming to be a burst. Without that half of the rule, the
    // clause would fire on every badly-recorded meeting and say something false about all of them.
    let message = try #require(RecordingHealthAdvisory.message(
        for: report(measured: fiveMinutes, atFullScale: fiveMinutes / 5,
                    worstSecond: ClippedSecond(framesMeasured: sampleRate, framesAtFullScale: sampleRate / 5))
    ))
    #expect(!message.contains("concentrated"), "\(message)")
    #expect(message.contains("flat-topped"), "\(message)")
}

@Test("A report from before F379 reads exactly as it did (F379)")
func anOlderReportIsUnchanged() throws {
    let withoutWorstSecond = try #require(RecordingHealthAdvisory.message(
        for: report(measured: fiveMinutes, atFullScale: 13_136, worstSecond: nil)
    ))
    #expect(!withoutWorstSecond.contains("concentrated"))
    #expect(withoutWorstSecond.contains("a small share of the"))
    // An empty second cannot be divided by, and must not read as clean either.
    #expect(ClippedSecond(framesMeasured: 0, framesAtFullScale: 0).fraction == nil)
}

@Test("The monitor finds the worst second, including the one a recording ends in (F379)")
func theMonitorTracksTheWorstSecond() {
    let monitor = RecordingHealthMonitor(startedAt: 0)
    // Three seconds: quiet, loud, quiet. The middle one is the burst.
    for (second, atFullScale) in [(0, 10), (1, 9_000), (2, 20)] {
        monitor.receive(
            .systemAudio,
            level: RecordingAudioLevel(
                rms: 0.5, peak: 0.99, framesMeasured: sampleRate, framesAtFullScale: atFullScale
            ),
            at: Double(second) + 0.5
        )
    }
    let worst = monitor.report().systemAudioWorstSecond
    #expect(worst?.framesAtFullScale == 9_000, "\(String(describing: worst))")
    #expect(worst?.framesMeasured == sampleRate)

    // The bucket still open when the recording ends counts too. Every recording ends mid-second,
    // and the last second is exactly where a user who stopped *because* of the noise heard it.
    monitor.receive(
        .systemAudio,
        level: RecordingAudioLevel(
            rms: 0.5, peak: 0.99, framesMeasured: sampleRate, framesAtFullScale: 30_000
        ),
        at: 3.5
    )
    #expect(monitor.report().systemAudioWorstSecond?.framesAtFullScale == 30_000)
}

@Test("The worst second survives a save and reload (F379)")
func theWorstSecondRoundTrips() throws {
    // Asserted against the encoded BYTES, not just the decoded value. A field missing from a
    // hand-written `CodingKeys` round-trips correctly in memory while never reaching disk —
    // `RecordingHealthReport` has a hand-written `init(from:)`, which is exactly the shape where
    // that happens.
    let original = report(
        measured: fiveMinutes,
        atFullScale: 13_136,
        worstSecond: ClippedSecond(framesMeasured: sampleRate, framesAtFullScale: 1_642)
    )
    let data = try JSONEncoder().encode(original)
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(text.contains("systemAudioWorstSecond"), "\(text)")
    #expect(text.contains("1642"), "\(text)")

    let decoded = try JSONDecoder().decode(RecordingHealthReport.self, from: data)
    #expect(decoded.systemAudioWorstSecond == original.systemAudioWorstSecond)

    // And a payload from before the field existed still decodes — the leniency every persisted
    // addition in this repo has to demonstrate (F188).
    var object = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    object.removeValue(forKey: "systemAudioWorstSecond")
    let older = try JSONSerialization.data(withJSONObject: object)
    let fromOlder = try JSONDecoder().decode(RecordingHealthReport.self, from: older)
    #expect(fromOlder.systemAudioWorstSecond == nil)
    #expect(fromOlder.systemAudioFramesAtFullScale == 13_136)
}
