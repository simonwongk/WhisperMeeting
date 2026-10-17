import Foundation
import Testing
@testable import WhisperCore

// F735 — since F419 a source clipped on one channel of two raises the clipping warning from its
// per-channel counts, while the live meter's peak and the saved, mixed file sit at half scale. The
// note said "System audio was at full scale for 2,400 of 2,400 samples" and nothing about where that
// was counted, so a user could open a waveform that never reaches full scale and find no problem.

@Test("A clipping note counted per channel says it was counted in the captured source, before mixing (F735)")
func perChannelClippingNoteSaysWhereItWasCounted() throws {
    let monitor = RecordingHealthMonitor(startedAt: 100)
    // One channel of two at full scale: the mono mix, and so the peak, is 0.5.
    monitor.receive(
        .systemAudio,
        level: .init(rms: 0.35, peak: 0.5, framesMeasured: 2_400, framesAtFullScale: 2_400),
        at: 101
    )
    _ = monitor.snapshot(at: 102, availableStorageBytes: 20_000_000_000)
    let message = try #require(RecordingHealthAdvisory.message(for: monitor.report()))
    #expect(message.contains("System audio was at full scale for 2,400 of 2,400 samples"), "\(message)")
    #expect(message.contains(RecordingHealthAdvisory.clippingCountedBeforeMixing), "\(message)")
}

@Test("Said once, after the counts, however many sources clipped (F735)")
func theWhereSentenceIsSaidOnce() throws {
    let monitor = RecordingHealthMonitor(startedAt: 100)
    monitor.receive(.systemAudio, level: .init(rms: 0.35, peak: 0.5, framesMeasured: 2_400, framesAtFullScale: 2_400), at: 101)
    monitor.receive(.microphone, level: .init(rms: 0.35, peak: 0.99, framesMeasured: 2_400, framesAtFullScale: 100), at: 101)
    _ = monitor.snapshot(at: 102, availableStorageBytes: 20_000_000_000)
    let message = try #require(RecordingHealthAdvisory.message(for: monitor.report()))
    #expect(message.components(separatedBy: RecordingHealthAdvisory.clippingCountedBeforeMixing).count == 2, "\(message)")
    let counts = try #require(message.range(of: "System audio was at full scale"))
    let note = try #require(message.range(of: RecordingHealthAdvisory.clippingCountedBeforeMixing))
    #expect(counts.upperBound <= note.lowerBound, "the sentence explains counts that come before it: \(message)")
}

@Test("A note with no count to explain does not carry it (F735 control)")
func notesWithoutACountDoNotSayIt() throws {
    // Nothing counted at full scale: "came close… nothing was clipped".
    let close = RecordingHealthMonitor(startedAt: 100)
    close.receive(.microphone, level: .init(rms: 0.4, peak: 0.99, framesMeasured: 2_400, framesAtFullScale: 0), at: 101)
    _ = close.snapshot(at: 102, availableStorageBytes: 20_000_000_000)
    let closeMessage = try #require(RecordingHealthAdvisory.message(for: close.report()))
    #expect(closeMessage.contains("nothing was clipped"), "\(closeMessage)")
    #expect(!closeMessage.contains(RecordingHealthAdvisory.clippingCountedBeforeMixing), "\(closeMessage)")
    // A report written before F346 has no counts at all.
    let old = RecordingHealthAdvisory.clippingNote(subject: "The microphone", measured: nil, atFullScale: nil, sustainedTail: "")
    #expect(!old.contains(RecordingHealthAdvisory.clippingCountedBeforeMixing))
}
