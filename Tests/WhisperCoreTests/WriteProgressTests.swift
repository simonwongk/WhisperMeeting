import Foundation
import Testing
@testable import WhisperCore

// F929 — a quit waiting for a saving stop is bounded on how long the save goes without completing a
// write, not on how long it takes: a one-hour mix legitimately runs for most of a minute, and a
// volume that has stopped answering completes nothing. These are the two pieces that decide it.

private func scratchHandle() throws -> (FileHandle, URL) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("F929-progress-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    return (try FileHandle(forWritingTo: url), url)
}

@Test("A write is counted only for the task that is counting, its child tasks included, never a detached one (F929)")
func writesAreCountedOnlyWhereBound() async throws {
    let (handle, url) = try scratchHandle()
    defer { try? handle.close(); try? FileManager.default.removeItem(at: url) }
    let progress = WriteProgress()

    try ThrowingFileHandleIO.write(Data([1]), to: handle)
    #expect(progress.ticks == 0, "nobody bound it, so nothing counts: dictation's writes go through here too")

    try await WriteProgress.$current.withValue(progress) {
        try ThrowingFileHandleIO.write(Data([1]), to: handle)
        try await Task { try ThrowingFileHandleIO.write(Data([1]), to: handle) }.value
        // A detached task inherits nothing; the stop's rebuild binds its own (AppModel).
        try await Task.detached { try ThrowingFileHandleIO.write(Data([1]), to: handle) }.value
    }
    #expect(progress.ticks == 2, "the bound task's write and its child's; not the detached one's")

    try ThrowingFileHandleIO.write(Data([1]), to: handle)
    #expect(progress.ticks == 2, "nothing counts once the binding has ended")
}

@Test("A write that fails is not progress (F929)")
func aFailedWriteIsNotCounted() throws {
    let (handle, url) = try scratchHandle()
    try handle.close()
    defer { try? FileManager.default.removeItem(at: url) }
    let progress = WriteProgress()
    WriteProgress.$current.withValue(progress) {
        #expect(throws: (any Error).self) { try ThrowingFileHandleIO.write(Data([1]), to: handle) }
    }
    #expect(progress.ticks == 0)
}

@Test("Work is stalled only after the bound passes with no new write, and every write starts the quiet over (F929)")
func theStallWatchMeasuresQuietNotDuration() {
    let start = ContinuousClock.now
    var watch = ProgressStallWatch(bound: .seconds(30), ticks: 5, now: start)
    // (Each answer is taken before it is asserted: `hasStalled` is mutating, and `#expect` would
    // capture the watch immutably.)
    let quietFor29 = watch.hasStalled(ticks: 5, now: start.advanced(by: .seconds(29)))
    #expect(!quietFor29)
    // A write at 29 s. By 58 s the save has run for longer than the bound, but was never quiet that long.
    let wroteAt29 = watch.hasStalled(ticks: 6, now: start.advanced(by: .seconds(29)))
    let at58 = watch.hasStalled(ticks: 6, now: start.advanced(by: .seconds(58)))
    let at59 = watch.hasStalled(ticks: 6, now: start.advanced(by: .seconds(59)))
    #expect(!wroteAt29)
    #expect(!at58)
    #expect(at59, "30 s with no write")
    // A count that changes in any direction is a change; wrapping round is not standing still.
    var wrapped = ProgressStallWatch(bound: .seconds(30), ticks: .max, now: start)
    let wrappedAt31 = wrapped.hasStalled(ticks: 0, now: start.advanced(by: .seconds(31)))
    #expect(!wrappedAt31)
}
