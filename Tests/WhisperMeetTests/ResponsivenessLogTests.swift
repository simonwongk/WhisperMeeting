import Darwin
import Foundation
import Testing
@testable import WhisperMeet

// F1088 — a press's timing log reads the key event's own time stamp, which is host ticks on Apple silicon and
// nanoseconds elsewhere; the reading that gives an age under a minute is the one taken, and nothing else is.
@Test("A key event's age is read from a stamp in host ticks or in nanoseconds, and a stamp that fits neither says nothing (F1088)")
func eventAgeReadsEitherClock() throws {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let ticksPerMillisecond = 1e6 * Double(timebase.denom) / Double(timebase.numer)
    let ticksNow: UInt64 = 20_000_000_000_000
    let nanosecondsNow: UInt64 = UInt64(Double(ticksNow) * Double(timebase.numer) / Double(timebase.denom))
    // 30 ms ago in host ticks.
    let tickStamp = ticksNow - UInt64(30 * ticksPerMillisecond)
    let fromTicks = try #require(ResponsivenessLog.eventAgeMilliseconds(tickStamp, ticks: ticksNow, nanoseconds: nanosecondsNow))
    #expect(abs(fromTicks - 30) < 0.5, "\(fromTicks)")
    // 45 ms ago in nanoseconds.
    let nanosecondStamp = nanosecondsNow - 45_000_000
    let fromNanoseconds = try #require(ResponsivenessLog.eventAgeMilliseconds(nanosecondStamp, ticks: ticksNow, nanoseconds: nanosecondsNow))
    #expect(abs(fromNanoseconds - 45) < 0.5, "\(fromNanoseconds)")
    // A synthesized event's 0, and a stamp from the future, say nothing.
    #expect(ResponsivenessLog.eventAgeMilliseconds(0, ticks: ticksNow, nanoseconds: nanosecondsNow) == nil)
    #expect(ResponsivenessLog.eventAgeMilliseconds(nanosecondsNow + 1_000, ticks: ticksNow, nanoseconds: nanosecondsNow) == nil)
    #expect(ResponsivenessLog.milliseconds(since: 2_000_000, to: 1_000_000) == 0)
}
