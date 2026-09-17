import Foundation
import Testing
@testable import WhisperCore

// Five instances of one defect were found on 2026-09-17 — F151's gap cap, F275's padding
// conversion, `FloatTrackMixer`'s front-padding, F287's transcript formatter, and then a sweep
// turned up five more. Every one was the same shape: a `Double` from decoded data or from wall
// clock, converted with `Int(_:)` or `Int64(_:)`, which **traps** on overflow in Swift rather than
// saturating — with the clamp, where there was one, on the wrong side of the conversion.
//
// Four were found by accident, one at a time. This is the shared conversion so the sixth is not
// found the same way: `Int(saturating:)` reads like `Int(exactly:)`, which is the standard library's
// own answer to the same question, so it is discoverable rather than a local helper someone has to
// know about.

@Test("An ordinary value converts unchanged")
func ordinaryValuesAreUnchanged() {
    #expect(Int(saturating: 0) == 0)
    #expect(Int(saturating: 42.4) == 42)
    #expect(Int(saturating: 42.6) == 43)
    #expect(Int(saturating: -7.5) == -8)
    #expect(Int64(saturating: 48_000.0) == 48_000)
}

@Test("A value past the representable range saturates instead of trapping")
func hugeValuesSaturate() {
    // `1e30` is finite, which is why `isFinite` guards did not help. This is the value that took
    // the app down on launch from a `meetings.json` that decoded cleanly (F287).
    #expect(Int(saturating: 1e30) == Int.max)
    #expect(Int(saturating: -1e30) == Int.min)
    #expect(Int64(saturating: 1e30) == Int64.max)
    #expect(Int64(saturating: -1e30) == Int64.min)
}

@Test("Infinity saturates and NaN is zero")
func nonFiniteValues() {
    #expect(Int(saturating: .infinity) == Int.max)
    #expect(Int(saturating: -.infinity) == Int.min)
    // NaN has no ordering, so no saturation is meaningful — 0 is the only answer that is not a
    // guess about which end it belongs at.
    #expect(Int(saturating: .nan) == 0)
    #expect(Int64(saturating: .nan) == 0)
}

@Test("The exact boundary does not trap")
func boundaryValues() {
    // `Double(Int.max)` rounds UP to 2^63, which is one past the range — the classic off-by-one in
    // a hand-written bounds check, and the reason this compares against the Double rather than
    // casting the Double to Int to compare.
    #expect(Int(saturating: Double(Int.max)) == Int.max)
    #expect(Int(saturating: Double(Int.min)) == Int.min)
    #expect(Int64(saturating: Double(Int64.max)) == Int64.max)
}

@Test("A saturated value still formats as a duration rather than as garbage")
func saturatedValueFormatsReadably() {
    // whisper-62's second finding in F287, and the one worth generalising: fixing the conversion
    // does not fix the bug, because the next operation on the clamped value can be wrong in its own
    // way. There, `String(format: "%d")` read a saturated hour count as 32-bit off the varargs list
    // and printed `-1395096463:46:40`. A test asserting only "did not crash" would have passed.
    let phrase = CaptureRestartPolicy.durationPhrase(1e30)
    #expect(!phrase.contains("-"), "a saturated duration printed as negative: \(phrase)")
    #expect(!phrase.isEmpty)
}
