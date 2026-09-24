import Testing
@testable import WhisperCore

@Test("press starts capture; short clip is discarded; long clip transcribes")
func sessionCapturePaths() {
    var s = DictationSession(minClipDuration: 0.35)
    #expect(s.handle(.startPressed) == .startCapture)
    #expect(s.state == .listening)

    var short = DictationSession(minClipDuration: 0.35)
    _ = short.handle(.startPressed)
    #expect(short.handle(.endPressed(clipDuration: 0.1)) == .discard)
    #expect(short.state == .idle)

    #expect(s.handle(.endPressed(clipDuration: 1.0)) == .transcribe)
    #expect(s.state == .transcribing)
}

@Test("transcript delivers when non-empty and fails when empty")
func sessionTranscriptPaths() {
    var s = DictationSession()
    _ = s.handle(.startPressed); _ = s.handle(.endPressed(clipDuration: 1))
    #expect(s.handle(.transcriptReady("hi")) == .deliver("hi"))
    #expect(s.state == .delivering)
    #expect(s.handle(.delivered) == DictationSession.Action.none)
    #expect(s.state == .done)
    #expect(s.handle(.dismiss) == .reset)
    #expect(s.state == .idle)

    var empty = DictationSession()
    _ = empty.handle(.startPressed); _ = empty.handle(.endPressed(clipDuration: 1))
    #expect(empty.handle(.transcriptReady("")) == DictationSession.Action.none)
    #expect(empty.state == .failed(.emptyTranscript))
}

@Test("press while busy flashes busy; engine failure fails the session")
func sessionGuards() {
    var s = DictationSession()
    _ = s.handle(.startPressed)
    #expect(s.handle(.startPressed) == .busy)
    #expect(s.state == .listening)

    _ = s.handle(.endPressed(clipDuration: 1))
    #expect(s.handle(.engineFailed("boom")) == DictationSession.Action.none)
    #expect(s.state == .failed(.engine("boom")))
}

@Test("a press while the last result is still showing starts the next capture (F443)")
func sessionPressAfterResultStartsCapture() {
    var delivered = DictationSession()
    _ = delivered.handle(.startPressed); _ = delivered.handle(.endPressed(clipDuration: 1))
    _ = delivered.handle(.transcriptReady("hi")); _ = delivered.handle(.delivered)
    #expect(delivered.state == .done)
    #expect(delivered.handle(.startPressed) == .startCapture)
    #expect(delivered.state == .listening)

    var empty = DictationSession()
    _ = empty.handle(.startPressed); _ = empty.handle(.endPressed(clipDuration: 1))
    _ = empty.handle(.transcriptReady(""))
    #expect(empty.handle(.startPressed) == .startCapture)
    #expect(empty.state == .listening)

    var failed = DictationSession()
    _ = failed.handle(.startPressed); _ = failed.handle(.engineFailed("boom"))
    #expect(failed.handle(.startPressed) == .startCapture)
    #expect(failed.state == .listening)

    // Still refused while a dictation is genuinely in flight.
    var transcribing = DictationSession()
    _ = transcribing.handle(.startPressed); _ = transcribing.handle(.endPressed(clipDuration: 1))
    #expect(transcribing.handle(.startPressed) == .busy)
    #expect(transcribing.state == .transcribing)
    _ = transcribing.handle(.transcriptReady("hi"))
    #expect(transcribing.handle(.startPressed) == .busy)
    #expect(transcribing.state == .delivering)
}
