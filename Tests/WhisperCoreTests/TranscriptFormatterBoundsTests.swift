import Foundation
import Testing
@testable import WhisperCore

// F287 — `Int(Double)` traps rather than saturating, and the clamp was on the wrong side of it.
//
// `timestamp` was `max(0, Int(seconds))` and `clock` was `max(0, Int(seconds.rounded()))`. The
// `max` runs AFTER the conversion, so it never gets the chance — the same shape whisper-37 found
// three times in the capture path, where a 30-second cap was applied after the conversion it was
// meant to bound.
//
// Reachable from a decodable index, which is what makes it worse than the unreadable-index cases
// F250 and F187 handle. `duration` is a plain `Double` in `MeetingRecord`, so a corrupt or
// hand-edited `meetings.json` carrying `1e30` decodes cleanly, reports `.complete` health, and then
// crashes the app while drawing the sidebar. A library the app considers healthy takes it down, and
// no amount of lenient decoding helps because the value decoded fine.
//
// Verified as a trap rather than assumed: a standalone program doing `max(0, Int(1e30))` exits 133
// (SIGTRAP). `isFinite` does not cover it — 1e30 is perfectly finite.

@Test("A wild duration formats instead of trapping")
func wildDurationsDoNotTrap() {
    // Each of these traps on `Int(_:)` before any clamp downstream of it can run.
    for wild in [1e30, 1e18, Double.greatestFiniteMagnitude, -1e30] {
        _ = TranscriptFormatter.clock(wild)
        _ = TranscriptFormatter.timestamp(wild)
    }
}

@Test("Infinities and NaN format instead of trapping")
func nonFiniteDurationsDoNotTrap() {
    for bad in [Double.infinity, -Double.infinity, Double.nan] {
        _ = TranscriptFormatter.clock(bad)
        _ = TranscriptFormatter.timestamp(bad)
    }
}

@Test("A clamped value reads as a duration, not as garbage")
func clampedValueIsStillADuration() {
    // The clamp must produce something a user can read as "implausibly long", not a negative or
    // wrapped number that looks like real data. Nothing claims the value is correct — the index
    // said something impossible — but the app must not present it as a small duration either.
    let formatted = TranscriptFormatter.clock(1e30)
    #expect(formatted.contains(":"))
    #expect(!formatted.contains("-"))
    #expect(TranscriptFormatter.clock(Double.nan) == "0:00")
    #expect(TranscriptFormatter.clock(-5) == "0:00")
    #expect(TranscriptFormatter.timestamp(Double.nan) == "00:00")
}

@Test("Ordinary durations are unchanged")
func ordinaryDurationsAreUnchanged() {
    // The regression guard: this is a formatter on every meeting row and every segment line.
    #expect(TranscriptFormatter.clock(0) == "0:00")
    #expect(TranscriptFormatter.clock(59.4) == "0:59")
    #expect(TranscriptFormatter.clock(59.6) == "1:00")
    #expect(TranscriptFormatter.clock(750) == "12:30")
    #expect(TranscriptFormatter.clock(3_600) == "1:00:00")
    #expect(TranscriptFormatter.clock(3_661) == "1:01:01")
    #expect(TranscriptFormatter.timestamp(0) == "00:00")
    #expect(TranscriptFormatter.timestamp(90) == "01:30")
    #expect(TranscriptFormatter.timestamp(3_700) == "61:40")
}
