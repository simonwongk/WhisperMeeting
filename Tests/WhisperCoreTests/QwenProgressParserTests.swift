import Foundation
import Testing
@testable import WhisperCore

// F101 — the Qwen helper, run with verbose=True, streams mlx-audio's "Processing chunks" tqdm bar to
// stderr. This parser turns those frames into determinate transcription progress so a long meeting
// shows an advancing bar (delivers F31). Frames below are captured verbatim from the installed
// mlx-audio 0.3.1 (multi-chunk run over a bench clip).

@Test("QwenProgressParser maps real 'Processing chunks' tqdm frames to a determinate fraction (F101)")
func qwenProgressParserParsesChunkBar() {
    var parser = QwenProgressParser()

    // tqdm rewrites the bar in place with carriage returns.
    let first = parser.consume("Processing chunks:  33%|███▎      | 1/3 [00:00<00:01,  1.70it/s]\r")
    #expect(first?.phase == .transcribing)
    #expect(abs((first?.fractionCompleted ?? 0) - 1.0 / 3.0) < 0.001)
    #expect(first?.estimatedSecondsRemaining == 1)

    let second = parser.consume("Processing chunks:  67%|██████▋   | 2/3 [00:00<00:00,  2.87it/s]\r")
    #expect(abs((second?.fractionCompleted ?? 0) - 2.0 / 3.0) < 0.001)

    let done = parser.consume("Processing chunks: 100%|██████████| 3/3 [00:00<00:00,  3.94it/s]\r")
    #expect(done?.fractionCompleted == 1.0)

    // Non-progress noise (model-load chatter) yields nothing.
    #expect(parser.consume("Some other stderr line about loading weights\n") == nil)
}

@Test("QwenProgressParser tolerates the initial 0/N frame with an unknown ETA (F101)")
func qwenProgressParserHandlesInitialFrame() {
    var parser = QwenProgressParser()
    let start = parser.consume("Processing chunks:   0%|          | 0/3 [00:00<?, ?it/s]\r")
    #expect(start?.fractionCompleted == 0.0)
    #expect(start?.estimatedSecondsRemaining == nil)   // "?" ETA is not a number
}
