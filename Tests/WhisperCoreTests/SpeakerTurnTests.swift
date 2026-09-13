import Foundation
import Testing
@testable import WhisperCore

// F218 — a diarization result is untrusted input. Every malformed interval must be rejected
// before it can reach storage or the UI, and the canonical fixture must survive intact.

private func turn(_ start: Double, _ end: Double, _ cluster: Int = 0,
                  _ kind: SpeakerTurnKind = .speech) -> SpeakerTurn {
    SpeakerTurn(startSeconds: start, endSeconds: end, clusterID: cluster, kind: kind)
}

@Test("A canonical ordered turn list validates unchanged (F218)")
func validationAcceptsCanonicalTurns() throws {
    let turns = [turn(0, 5), turn(5, 10, 1), turn(10, 12)]
    let validated = try SpeakerTurns.validate(turns, durationSeconds: 12)
    #expect(validated == turns)
}

@Test("Non-finite bounds are rejected (F218)")
func validationRejectsNonFinite() {
    #expect(throws: SpeakerTurnValidationError.notFinite) {
        try SpeakerTurns.validate([turn(0, .nan)], durationSeconds: 10)
    }
    #expect(throws: SpeakerTurnValidationError.notFinite) {
        try SpeakerTurns.validate([turn(.infinity, 1)], durationSeconds: 10)
    }
}

@Test("Negative, reversed, and zero-length intervals are rejected (F218)")
func validationRejectsImpossibleIntervals() {
    #expect(throws: SpeakerTurnValidationError.negativeStart) {
        try SpeakerTurns.validate([turn(-1, 5)], durationSeconds: 10)
    }
    #expect(throws: SpeakerTurnValidationError.reversedInterval) {
        try SpeakerTurns.validate([turn(5, 5)], durationSeconds: 10)
    }
    #expect(throws: SpeakerTurnValidationError.reversedInterval) {
        try SpeakerTurns.validate([turn(6, 5)], durationSeconds: 10)
    }
}

@Test("A turn beyond the recording duration is rejected (F218)")
func validationRejectsOutOfRange() {
    #expect(throws: SpeakerTurnValidationError.exceedsDuration) {
        try SpeakerTurns.validate([turn(0, 11)], durationSeconds: 10)
    }
}

@Test("A negative cluster id is rejected (F218)")
func validationRejectsNegativeCluster() {
    #expect(throws: SpeakerTurnValidationError.negativeCluster) {
        try SpeakerTurns.validate([turn(0, 5, -1)], durationSeconds: 10)
    }
}

@Test("Unsorted turns are rejected rather than silently reordered (F218)")
func validationRejectsUnsortedTurns() {
    #expect(throws: SpeakerTurnValidationError.unsortedTurns) {
        try SpeakerTurns.validate([turn(5, 10), turn(0, 4)], durationSeconds: 10)
    }
}

@Test("An absurd turn count is rejected so a malformed file cannot exhaust memory (F218)")
func validationRejectsTooManyTurns() {
    let many = (0..<(SpeakerTurns.maximumTurnCount + 1)).map { index in
        turn(Double(index) * 0.001, Double(index) * 0.001 + 0.0005)
    }
    #expect(throws: SpeakerTurnValidationError.tooManyTurns) {
        try SpeakerTurns.validate(many, durationSeconds: 100_000)
    }
}

@Test("An unknown persisted kind decodes leniently as uncertain, never as confident speech (F218)")
func unknownKindDecodesAsUncertain() throws {
    let json = Data(#"{"startSeconds":0,"endSeconds":1,"clusterID":0,"kind":"telepathy"}"#.utf8)
    let decoded = try JSONDecoder().decode(SpeakerTurn.self, from: json)
    #expect(decoded.kind == .uncertain)
}

@Test("A duration tolerance absorbs floating-point drift at the very end of a recording (F218)")
func validationToleratesEndOfFileRounding() throws {
    // The runtime reports its own duration to 3 dp; a turn may end a hair past ours.
    let turns = [turn(0, 12.0004)]
    let validated = try SpeakerTurns.validate(turns, durationSeconds: 12)
    #expect(validated.count == 1)
}

@Test("A kind written by a newer build survives a read-modify-write unchanged (F218)")
func unknownKindSurvivesReEncoding() throws {
    // AGENTS.md:418 — "old data still decodes" is half a review. `renameSpeaker` loads the whole
    // artifact, changes one alias and writes it all back, so a kind this build cannot name must
    // come out the far side spelled exactly as it went in.
    let json = Data(#"{"startSeconds":0,"endSeconds":1,"clusterID":0,"kind":"crosstalk"}"#.utf8)
    let decoded = try JSONDecoder().decode(SpeakerTurn.self, from: json)
    #expect(decoded.kind == .uncertain)   // degraded for DISPLAY

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let text = String(decoding: try encoder.encode(decoded), as: UTF8.self)
    #expect(text.contains("\"kind\":\"crosstalk\""))   // preserved on DISK
    #expect(!text.contains("uncertain"))
}

@Test("A non-finite recording duration is rejected rather than trusted as a yardstick (F218)")
func validationRejectsNonFiniteDuration() {
    // The duration is this gate's own yardstick, and it was the one number the gate did not check.
    // `max(0, .infinity) + tolerance` accepts every out-of-range turn; `max(0, .nan) + tolerance`
    // rejects every turn. One class of bad input, two opposite outcomes, neither of them a policy.
    #expect(throws: SpeakerTurnValidationError.invalidDuration) {
        try SpeakerTurns.validate([turn(0, 999_999)], durationSeconds: .infinity)
    }
    #expect(throws: SpeakerTurnValidationError.invalidDuration) {
        try SpeakerTurns.validate([turn(0, 5)], durationSeconds: .nan)
    }
}
