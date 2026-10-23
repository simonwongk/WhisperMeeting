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

// F1090 — a press's pill came 44–194 ms after its microphone start and field check were done, and the log could not say
// whether other work held the main thread or the drawing itself was slow. So the turn's end is read twice: when the run loop
// starts to go to sleep, before the observers that lay out and commit its drawing, and after the commit. Both readings come
// from the same turn, in that order.
@Test("The turn's end is read before its drawing is laid out and after it is committed, in that order (F1090)")
@MainActor
func turnEndIsReadBeforeAndAfterItsDrawing() throws {
    let began = ResponsivenessLog.now()
    var readings: (settled: UInt64, drawn: UInt64)?
    ResponsivenessLog.whenThisTurnDraws { settled, drawn in readings = (settled, drawn) }
    // A run loop with nothing to wait on returns without going to sleep, so it is given a timer, as the app's always
    // has sources. Spun until it has gone to sleep once; the bound only keeps a broken observer from hanging the suite.
    let timer = Timer(timeInterval: 0.005, repeats: false) { _ in }
    RunLoop.main.add(timer, forMode: .common)
    defer { timer.invalidate() }
    for _ in 0..<500 {
        if readings != nil { break }
        _ = CFRunLoopRunInMode(.defaultMode, 0.01, true)
    }
    let (settled, drawn) = try #require(readings)
    #expect(began <= settled)
    #expect(settled <= drawn)
}
