import Foundation
import Testing
@testable import WhisperCore

// F219 — the runtime speaks a line grammar, and every rule below was observed in a real run:
// non-dense speaker ids, a -2.0 confidence sentinel, a config preamble before `Started`, and four
// distinct failure markers that all exit 255.

@Test("A segment line parses into a raw turn (F219)")
func parserReadsASegmentLine() throws {
    let turn = try #require(DiarizationOutputParser.turn(from: "0.031 -- 8.485 speaker_00 confidence=0.707"))
    #expect(turn.startSeconds == 0.031)
    #expect(turn.endSeconds == 8.485)
    #expect(turn.rawSpeaker == 0)
    #expect(turn.confidence == 0.707)
}

@Test("A segment line without confidence parses with a nil confidence (F219)")
func parserReadsALineWithoutConfidence() throws {
    let turn = try #require(DiarizationOutputParser.turn(from: "8.975 -- 18.695 speaker_02"))
    #expect(turn.rawSpeaker == 2)
    #expect(turn.confidence == nil)
}

@Test("A single-cluster run emits confidence=n/a, and the turn still parses (F219)")
func parserReadsUnavailableConfidence() throws {
    // Observed verbatim on the F217 corpus: whenever exactly one cluster forms, the runtime prints
    // the literal string `n/a` rather than a number or the -2.0 sentinel. A pattern that accepts
    // only digits drops the entire line, so a monologue would diarize to nothing at all.
    let turn = try #require(DiarizationOutputParser.turn(from: "0.470 -- 17.159 speaker_00 confidence=n/a"))
    #expect(turn.startSeconds == 0.470)
    #expect(turn.rawSpeaker == 0)
    #expect(turn.confidence == nil)
}

@Test("Preamble and progress lines are not turns (F219)")
func parserIgnoresNonSegmentLines() {
    #expect(DiarizationOutputParser.turn(from: "Started") == nil)
    #expect(DiarizationOutputParser.turn(from: "OfflineSpeakerDiarizationConfig(segmentation=...)") == nil)
    #expect(DiarizationOutputParser.turn(from: "") == nil)
    #expect(DiarizationOutputParser.turn(from: "progress 50.00%") == nil)
}

@Test("Progress lines parse to a 0...1 fraction (F219)")
func parserReadsProgress() {
    #expect(DiarizationOutputParser.progress(from: "progress 1.09%") == 0.0109)
    #expect(DiarizationOutputParser.progress(from: "progress 100.00%") == 1.0)
    #expect(DiarizationOutputParser.progress(from: "Duration : 56.190 s") == nil)
}

@Test("Sparse speaker ids are remapped densely in first-appearance order (F219)")
func parserDensifiesSpeakerIDs() {
    // Real output for a two-speaker file: speaker_00 and speaker_02, with no speaker_01.
    let raw = [
        RawDiarizationTurn(startSeconds: 0, endSeconds: 8, rawSpeaker: 0, confidence: 0.7),
        RawDiarizationTurn(startSeconds: 8, endSeconds: 18, rawSpeaker: 2, confidence: 0.6),
        RawDiarizationTurn(startSeconds: 19, endSeconds: 27, rawSpeaker: 0, confidence: 0.6)
    ]
    let turns = DiarizationOutputParser.densify(raw, uncertainBelowConfidence: 0)
    #expect(turns.map(\.clusterID) == [0, 1, 0])
    #expect(turns.allSatisfy { $0.kind == .speech })
}

@Test("The -2.0 confidence sentinel means unavailable, not a low score (F219)")
func parserTreatsSentinelConfidenceAsUnavailable() {
    let raw = [RawDiarizationTurn(startSeconds: 0, endSeconds: 8, rawSpeaker: 0, confidence: -2.0)]
    // A sentinel must not be compared against the threshold as if it were a real score.
    let turns = DiarizationOutputParser.densify(raw, uncertainBelowConfidence: 0.5)
    #expect(turns[0].kind == .speech)
}

@Test("The -2.0 sentinel arrives as a line, and the turn survives it (F219)")
func parserReadsSentinelConfidenceFromALine() throws {
    // The test above hands `densify` a hand-built RawDiarizationTurn, so nothing ever feeds the
    // sentinel through as a LINE and the `-?` in the pattern is uncovered. Removing the sign is not
    // cosmetic: the optional group then cannot match, `\s*$` fails, and the WHOLE line is dropped —
    // the turn is discarded outright rather than merely de-scored, which is the failure this
    // parser's own comment warns about for the `n/a` form.
    let turn = try #require(DiarizationOutputParser.turn(from: "0.031 -- 8.485 speaker_00 confidence=-2.0"))
    #expect(turn.startSeconds == 0.031)
    #expect(turn.confidence == DiarizationOutputParser.unavailableConfidence)
    // And it is still "no score", not a score below every threshold.
    #expect(DiarizationOutputParser.densify([turn], uncertainBelowConfidence: 0.5)[0].kind == .speech)
}

@Test("A genuinely low confidence becomes an uncertain turn rather than a confident label (F219)")
func parserAbstainsBelowTheConfidenceFloor() {
    let raw = [
        RawDiarizationTurn(startSeconds: 0, endSeconds: 8, rawSpeaker: 0, confidence: 0.2),
        RawDiarizationTurn(startSeconds: 8, endSeconds: 16, rawSpeaker: 1, confidence: 0.9)
    ]
    let turns = DiarizationOutputParser.densify(raw, uncertainBelowConfidence: 0.5)
    #expect(turns[0].kind == .uncertain)
    #expect(turns[1].kind == .speech)
}

@Test("Each runtime failure marker maps to its own error (F219)")
func parserClassifiesFailures() {
    #expect(DiarizationOutputParser.classify(errorOutput: "Errors in config!", exitStatus: 255)
        == .runtimeDamaged("Errors in config!"))
    #expect(DiarizationOutputParser.classify(errorOutput: "Failed to read /tmp/x.wav", exitStatus: 255)
        == .audioUnreadable("Failed to read /tmp/x.wav"))
    #expect(DiarizationOutputParser.classify(errorOutput: "Expect sample rate 16000. Given: 44100", exitStatus: 255)
        == .sampleRateMismatch("Expect sample rate 16000. Given: 44100"))
    #expect(DiarizationOutputParser.classify(errorOutput: "something else", exitStatus: 3)
        == .processFailed("something else"))
    // A crash before any output leaves the marker text empty; the exit status is then the only
    // evidence there is, and it is passed into this very function.
    #expect(DiarizationOutputParser.classify(errorOutput: "   \n ", exitStatus: 137)
        == .processFailed("The analyzer exited with status 137."))
}
