import Foundation
import Testing
@testable import WhisperCore

// F216/F219 — `SpeakerTurns.densify` is the runtime-agnostic half of what the retired sherpa-onnx
// output parser did: remap whatever cluster ids a runtime allocated onto dense `0..<n` in
// first-appearance order, so "Speaker 1" is the first voice heard. The line-grammar half — the
// `speaker_NN confidence=…` segment regex, the `progress NN.NN%` form, the `n/a` and -2.0
// confidence sentinels, and the four exit-255 failure markers — went with the runtime that spoke
// it. These two tests moved here unchanged in substance when the parser was deleted.

@Test("Sparse runtime cluster ids are remapped densely in first-appearance order (F219)")
func densifyRemapsIDsInFirstAppearanceOrder() {
    // A runtime that skips ids is not hypothetical: sherpa-onnx really did emit speaker_00 and
    // speaker_02 with no speaker_01 for a two-speaker file, and FluidAudio allocates "S1"/"S5".
    // Either way the second voice heard must be shown as the second speaker.
    let raw = [
        RawDiarizationTurn(startSeconds: 0, endSeconds: 8, rawSpeaker: 0, confidence: 0.7),
        RawDiarizationTurn(startSeconds: 8, endSeconds: 18, rawSpeaker: 2, confidence: 0.6),
        RawDiarizationTurn(startSeconds: 19, endSeconds: 27, rawSpeaker: 0, confidence: 0.6)
    ]
    let turns = SpeakerTurns.densify(raw, uncertainBelowConfidence: 0)
    #expect(turns.map(\.clusterID) == [0, 1, 0])
    #expect(turns.allSatisfy { $0.kind == .speech })
}

@Test("A runtime id that is not a number is remapped the same way (F216)")
func densifyRemapsNonNumericIDs() {
    // The reason `rawSpeaker` is generic rather than an `Int`. FluidAudio's ids are strings, and
    // parsing digits back out of them would fail open the day one stops being "S" + digits: every
    // turn would collapse onto one cluster and two voices would be shown as one confidently
    // labelled speaker — the single error `SpeakerOverlay` cannot detect, because it sees one
    // cluster with no competitor and no overlap. Keyed on the string, an unfamiliar id is just a
    // different key.
    let raw = [
        RawDiarizationTurn(startSeconds: 0, endSeconds: 2, rawSpeaker: "S2", confidence: nil),
        RawDiarizationTurn(startSeconds: 2, endSeconds: 4, rawSpeaker: "cluster-a", confidence: nil),
        RawDiarizationTurn(startSeconds: 4, endSeconds: 6, rawSpeaker: "S2", confidence: nil)
    ]
    let turns = SpeakerTurns.densify(raw, uncertainBelowConfidence: 0.5)
    #expect(turns.map(\.clusterID) == [0, 1, 0])
    // No score is not a low score: a runtime that reports no confidence must not have every one of
    // its turns marked uncertain and therefore labelled with nothing at all.
    #expect(turns.allSatisfy { $0.kind == .speech })
}

@Test("A genuinely low confidence becomes an uncertain turn rather than a confident label (F219)")
func densifyAbstainsBelowTheConfidenceFloor() {
    let raw = [
        RawDiarizationTurn(startSeconds: 0, endSeconds: 8, rawSpeaker: 0, confidence: 0.2),
        RawDiarizationTurn(startSeconds: 8, endSeconds: 16, rawSpeaker: 1, confidence: 0.9)
    ]
    let turns = SpeakerTurns.densify(raw, uncertainBelowConfidence: 0.5)
    #expect(turns[0].kind == .uncertain)
    #expect(turns[1].kind == .speech)
}
