import Foundation
import Testing
@testable import WhisperCore

// F400 — two ways the clipping sentence was not a function of its inputs alone.
//
// The counts it prints come from `meetings.json` through `try? decodeIfPresent(Int.self, …)`,
// which accepts any `Int`. The guard checked `atFullScale <= measured` and not `atFullScale >= 0`,
// so a decoded `-5` printed "reached full scale on -5 of 100 samples — about 1 in -20", and a
// decoded worst second of 96,000 frames inside a 48,000-frame second printed "The worst second of
// it was 200% at full scale". Both are the F187/F362 shape: a plainly-typed number that decodes
// cleanly and reaches copy nobody checked it against.
//
// The digits were also grouped by `Locale.current`, while the percentage beside them came from
// `String(format:)` and is always POSIX. On a de_DE host the same sentence read "13.136 of
// 14.400.000 samples (0.09%)" — '.' as both the grouping separator and the decimal point, one
// clause apart — and four existing assertions passed only because the machine writing them was
// en_US.

// The source assertion that the pin is still there lives in `WhisperMeetTests`, because
// `SourceAssertion` does — see `ClippingSentenceLocaleGuardTests`.

// MARK: - Locale

@Test("Grouped digits do not follow the host's locale (F400)")
func groupedDigitsArePinnedNotInherited() throws {
    // The demonstration first: the formatter really is locale-sensitive, so pinning it is not a
    // no-op dressed up as a fix.
    #expect(RecordingHealthAdvisory.grouped(14_400_000, locale: Locale(identifier: "de_DE"))
            == "14.400.000")
    #expect(RecordingHealthAdvisory.grouped(14_400_000, locale: Locale(identifier: "en_US"))
            == "14,400,000")

    // And the shipped path does not consult the host. This is what the four existing assertions
    // were relying on by accident.
    #expect(RecordingHealthAdvisory.grouped(14_400_000) == "14,400,000")
}

// MARK: - Bounds on decoded counts

@Test("A negative full-scale count says the report is unusable, not \"1 in -20\" (F400)")
func aNegativeDecodedCountIsRefused() {
    let note = RecordingHealthAdvisory.clippingNote(
        subject: "System audio", measured: 100, atFullScale: -5, sustainedTail: ""
    )
    #expect(note.contains("predates the measurement"),
            "an impossible count means the report cannot be read; got: \(note)")
    #expect(!note.contains("-5"))
    #expect(!note.contains("-20"))
}

@Test("A worst second holding more clipped frames than it has is ignored (F400)")
func aWorstSecondOverOneHundredPercentIsIgnored() {
    let note = RecordingHealthAdvisory.clippingNote(
        subject: "System audio",
        measured: 14_400_000,
        atFullScale: 13_136,
        worstSecond: ClippedSecond(framesMeasured: 48_000, framesAtFullScale: 96_000),
        sustainedTail: ""
    )
    #expect(!note.contains("200%"), "got: \(note)")
    #expect(!note.contains("worst second"),
            "a second that cannot exist locates nothing; got: \(note)")
}

@Test("A worst second larger than the whole recording is ignored (F400)")
func aWorstSecondBiggerThanTheRecordingIsIgnored() {
    let note = RecordingHealthAdvisory.clippingNote(
        subject: "System audio",
        measured: 14_400_000,
        atFullScale: 13_136,
        // More frames in "one second" than the entire recording holds.
        worstSecond: ClippedSecond(framesMeasured: 100_000_000, framesAtFullScale: 50_000_000),
        sustainedTail: ""
    )
    #expect(!note.contains("worst second"), "got: \(note)")
}

@Test("A real concentrated burst is still reported (F400)")
func anHonestWorstSecondStillReports() {
    // The control. The bounds above must not silence the clause this was built for (F379).
    let note = RecordingHealthAdvisory.clippingNote(
        subject: "System audio",
        measured: 14_400_000,
        atFullScale: 13_136,
        worstSecond: ClippedSecond(framesMeasured: 48_000, framesAtFullScale: 24_000),
        sustainedTail: ""
    )
    #expect(note.contains("worst second"), "got: \(note)")
    #expect(note.contains("50%"), "got: \(note)")
}
