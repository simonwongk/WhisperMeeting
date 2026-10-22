import Foundation
import Testing
@testable import WhisperCore

// F1051 — after F982, a system track whose every buffer fails to save gets F386's after-meeting note:
// "Audio stopped being written to disk partway through … What was written before that point is
// intact." For a track that failed from its first buffer nothing was written, there was no "point"
// before which anything is intact, and a format failure is not about the disk. The saved report kept
// only the warning, so the note could not tell. It now keeps, per track, whether any of it was saved.

private let quiet = RecordingAudioLevel(rms: 0.2, peak: 0.3)

/// Ten buffers a second for `seconds`. `failing` fails every write from the first buffer; the other
/// track lands.
private func capture(failing: Set<RecordingChannel>, seconds: Int = 20) -> RecordingHealthMonitor {
    let monitor = RecordingHealthMonitor(startedAt: 0)
    for tick in 1..<(seconds * 10) {
        let time = Double(tick) / 10
        for channel in [RecordingChannel.microphone, .systemAudio] {
            if failing.contains(channel) {
                monitor.recordWriteOutcome(channel, succeeded: false, cause: .format)
            } else {
                monitor.recordWriteOutcome(channel, succeeded: true)
                monitor.receive(channel, level: quiet, at: time)
            }
        }
        if tick % 10 == 0 { _ = monitor.snapshot(at: time, availableStorageBytes: nil) }
    }
    return monitor
}

@Test("A system track that failed from its first buffer is noted as never saved, not as cut short (F1051)")
func aTrackFailingFromItsFirstBufferIsNotedAsNeverSaved() {
    let report = capture(failing: [.systemAudio]).report()
    #expect(report.warnings.contains(.captureWritesFailing), "sanity: \(report.warnings)")
    let note = RecordingHealthAdvisory.message(for: report) ?? ""
    #expect(note.contains("System audio could not be saved at any point, so none of it was kept."), "\(note)")
    #expect(!note.contains("partway"), "nothing of it was written, so it was not cut short: \(note)")
    #expect(!note.contains("before that point"), "\(note)")
    #expect(!note.contains("disk"), "a format failure is not about the disk: \(note)")
}

@Test("The report keeps, per track, whether anything of a failing track was saved (F1051)")
func theReportKeepsWhatEachTrackLost() {
    let systemOnly = capture(failing: [.systemAudio]).report()
    #expect(systemOnly.systemAudioWriteLoss == RecordingHealthReport.nothingSaved)
    #expect(systemOnly.microphoneWriteLoss == nil, "the microphone's writes never failed")

    // Saved for a while, then failing: part of it was kept.
    let monitor = RecordingHealthMonitor(startedAt: 0)
    for tick in 1..<200 {
        let time = Double(tick) / 10
        monitor.recordWriteOutcome(.systemAudio, succeeded: true)
        monitor.receive(.systemAudio, level: quiet, at: time)
        let saved = tick < 50
        monitor.recordWriteOutcome(.microphone, succeeded: saved, cause: .storage)
        if saved { monitor.receive(.microphone, level: quiet, at: time) }
        if tick % 10 == 0 { _ = monitor.snapshot(at: time, availableStorageBytes: nil) }
    }
    let partly = monitor.report()
    #expect(partly.microphoneWriteLoss == RecordingHealthReport.partSaved)
    #expect(partly.systemAudioWriteLoss == nil)
    let note = RecordingHealthAdvisory.message(for: partly) ?? ""
    #expect(note.contains("Microphone audio stopped being saved partway through, so part of it was not kept."), "\(note)")

    let both = capture(failing: [.microphone, .systemAudio]).report()
    #expect(both.microphoneWriteLoss == RecordingHealthReport.nothingSaved)
    #expect(both.systemAudioWriteLoss == RecordingHealthReport.nothingSaved)
    let bothNote = RecordingHealthAdvisory.message(for: both) ?? ""
    #expect(bothNote.contains("No audio could be saved at any point during this recording, so none of it was kept."), "\(bothNote)")
}

@Test("A report written before F1051, or with a loss this build cannot name, keeps F386's sentence (F1051 control)")
func anOlderReportKeepsTheGeneralSentence() throws {
    let older = Data("""
        {"warnings":["captureWritesFailing"],"worstStatus":"atRisk",
         "microphoneStaleSeconds":0,"systemAudioStaleSeconds":0,"systemAudioEverDetected":true}
        """.utf8)
    let newer = Data("""
        {"warnings":["captureWritesFailing"],"worstStatus":"atRisk",
         "microphoneStaleSeconds":0,"systemAudioStaleSeconds":0,"systemAudioEverDetected":true,
         "systemAudioWriteLoss":"somethingNewer"}
        """.utf8)
    for data in [older, newer] {
        let report = try JSONDecoder().decode(RecordingHealthReport.self, from: data)
        let note = RecordingHealthAdvisory.message(for: report) ?? ""
        #expect(note.contains("Audio stopped being written to disk partway through"), "\(note)")
    }
}

@Test("What a track lost reaches disk, reads back, and an older reader ignores it (F1051)")
func theLossRoundTripsBothWays() throws {
    let report = RecordingHealthReport(
        warnings: [.captureWritesFailing], worstStatus: .atRisk,
        microphoneStaleSeconds: 0, systemAudioStaleSeconds: 0, systemAudioEverDetected: true,
        microphoneWriteLoss: RecordingHealthReport.partSaved, systemAudioWriteLoss: RecordingHealthReport.nothingSaved
    )
    let data = try JSONEncoder().encode(report)
    let decoded = try JSONDecoder().decode(RecordingHealthReport.self, from: data)
    #expect(decoded == report)
    // The previously shipped build's report has only the fields before F1051, decoded by a keyed
    // container that ignores keys it does not know. Its shape, as that build declared it:
    struct ShippedReport: Decodable {
        let warnings: [String]
        let worstStatus: String
        let microphoneStaleSeconds: Double
        let systemAudioStaleSeconds: Double
        let systemAudioEverDetected: Bool
    }
    let shipped = try JSONDecoder().decode(ShippedReport.self, from: data)
    #expect(shipped.warnings == ["captureWritesFailing"])
    #expect(String(decoding: data, as: UTF8.self).contains(#""systemAudioWriteLoss":"nothingSaved""#))
}
