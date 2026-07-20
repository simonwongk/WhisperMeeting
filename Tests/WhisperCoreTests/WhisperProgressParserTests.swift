import Foundation
import Testing
@testable import WhisperCore

@Test("Transcription tqdm bar yields frame-accurate progress and remaining time")
func parsesTranscriptionBar() {
    var parser = WhisperProgressParser()
    let progress = parser.consume(
        "\r 62%|██████▏   | 16740/27000 [00:45<00:27, 380.12frames/s]"
    )
    #expect(progress?.phase == .transcribing)
    #expect(abs((progress?.fractionCompleted ?? 0) - 16740.0 / 27000.0) < 0.0001)
    #expect(progress?.estimatedSecondsRemaining == 27)
}

@Test("First-use model download bar is reported as a download, not transcription")
func parsesDownloadBar() {
    var parser = WhisperProgressParser()
    let progress = parser.consume(
        "\r 46%|████▌     | 1.42G/3.09G [00:12<00:14, 120MiB/s]"
    )
    #expect(progress?.phase == .downloadingModel)
    #expect(abs((progress?.fractionCompleted ?? 0) - 0.46) < 0.0001)
    #expect(progress?.estimatedSecondsRemaining == 14)
}

@Test("A bar split across two chunks is assembled before it is reported")
func assemblesBarAcrossChunks() {
    var parser = WhisperProgressParser()
    #expect(parser.consume("\r 10%|█") == nil)
    let progress = parser.consume(
        "         | 2700/27000 [00:05<00:45, 100.0frames/s]\r"
    )
    #expect(progress?.phase == .transcribing)
    #expect(abs((progress?.fractionCompleted ?? 0) - 0.1) < 0.0001)
    #expect(progress?.estimatedSecondsRemaining == 45)
}

@Test("The newest bar in a chunk with several updates wins")
func reportsNewestBar() {
    var parser = WhisperProgressParser()
    let progress = parser.consume(
        "\r 20%|▓ | 5400/27000 [00:10<00:40, 100frames/s]"
            + "\r 40%|▓▓ | 10800/27000 [00:20<00:30, 100frames/s]"
    )
    #expect(abs((progress?.fractionCompleted ?? 0) - 0.4) < 0.0001)
    #expect(progress?.estimatedSecondsRemaining == 30)
}

@Test("Ordinary log lines are not mistaken for progress")
func ignoresNonProgressText() {
    var parser = WhisperProgressParser()
    #expect(parser.consume("Detecting language using up to the first 30 seconds\n") == nil)
    #expect(parser.consume("model could not load\n") == nil)
}

@Test("An unknown remaining time leaves the estimate empty but still reports progress")
func handlesUnknownRemaining() {
    var parser = WhisperProgressParser()
    let progress = parser.consume("\r  0%|          | 0/27000 [00:00<?, ?frames/s]")
    #expect(progress?.phase == .transcribing)
    #expect(progress?.fractionCompleted == 0)
    #expect(progress?.estimatedSecondsRemaining == nil)
}

@Test("The same bar is not re-emitted when a later chunk adds no new progress")
func doesNotReemitUnchangedProgress() {
    var parser = WhisperProgressParser()
    let first = parser.consume("\r 30%|▓ | 8100/27000 [00:10<00:23, 100frames/s]")
    #expect(first?.fractionCompleted != nil)
    // A chunk with no complete new bar must not replay the retained bar as fresh progress.
    #expect(parser.consume("some unrelated log line\n") == nil)
}

@Test("Clock strings convert hours, minutes, and seconds to a total")
func convertsClockStrings() {
    #expect(WhisperProgressParser.seconds(fromClock: "27") == 27)
    #expect(WhisperProgressParser.seconds(fromClock: "01:30") == 90)
    #expect(WhisperProgressParser.seconds(fromClock: "1:02:03") == 3723)
    #expect(WhisperProgressParser.seconds(fromClock: "?") == nil)
}
