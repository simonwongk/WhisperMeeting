import Foundation
import Testing
@testable import WhisperCore

// F400 — the guard for an *absence*, kept here only because `SourceAssertion` lives in this
// target. The behavioural half is `ClippingSentenceBoundsTests` in `WhisperCoreTests`.

@Test("The clipping sentence's number formatter still pins its locale (F400)")
func theClippingFormatterStillPinsItsLocale() throws {
    // A `NumberFormatter` with no locale follows `Locale.current`, while `percent` in the same
    // file uses `String(format:)` and always writes '.' as the decimal point. On a de_DE host the
    // two met in one sentence — "13.136 of 14.400.000 samples (0.09%)".
    //
    // A value assertion cannot catch the regression: on an en_US machine an unpinned formatter
    // produces exactly the right answer, which is why four existing assertions passed for four
    // months while being wrong everywhere else. The failure is the missing line, so the missing
    // line is what is checked.
    let source = try SourceAssertion.uncommentedSource(
        "Sources/WhisperCore/RecordingHealthAdvisory.swift"
    )
    #expect(source.contains("formatter.locale = locale"),
            "the grouping formatter must pin its locale, or it follows the host's")
    #expect(source.contains(#"Locale(identifier: "en_US")"#),
            "en_US, not en_US_POSIX — POSIX has no digit grouping and would print 14400000")
}
