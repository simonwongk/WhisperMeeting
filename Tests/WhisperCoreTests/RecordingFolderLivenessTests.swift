import Foundation
import Testing
@testable import WhisperCore

// F279 — F255's residual gap: a recorder that holds no lease at all.
//
// F255's gate rests on "a live second instance never holds the lease", which covers a recorder
// holding `.held`. It does not cover a recorder holding NEITHER, because `writerLease` is sampled
// once in `MeetingStore.init` and never refreshed: A holds it and quits, B still believes
// `.heldElsewhere` for the rest of its life, B records on no lease, and C then launches, acquires
// `.held`, and rebuilds B's live folder. That is F255 verbatim.
//
// The test is direct rather than timed. A live capture appends frames continuously — the callback
// delivers buffers whether or not anyone is speaking — so a silent room still grows the file, and
// a crashed one never grows at all. Two samples answer it with no window to re-derive and no
// penalty for relaunching seconds after a crash.

private func makeFolder(_ label: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Liveness-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test("A folder whose tracks grow between samples is live")
func growingFolderReadsAsLive() throws {
    let directory = try makeFolder("growing")
    defer { try? FileManager.default.removeItem(at: directory) }
    let track = directory.appendingPathComponent("system-audio.f32")
    try Data(repeating: 0, count: 4_000).write(to: track)

    let before = RecordingFolderLiveness.sample(in: directory)
    try Data(repeating: 0, count: 8_000).write(to: track)
    let after = RecordingFolderLiveness.sample(in: directory)

    #expect(RecordingFolderLiveness.isGrowing(from: before, to: after))
}

@Test("A folder that is not being written reads as dead, however soon you look")
func staticFolderReadsAsDead() throws {
    // The counterpart that keeps the feature working. A probe that deferred every recovery would
    // break recovery silently, and "however soon you look" is the property a freshness window
    // could not give: a user relaunching seconds after a crash still gets their recording back.
    let directory = try makeFolder("static")
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(repeating: 0, count: 4_000)
        .write(to: directory.appendingPathComponent("system-audio.f32"))
    try Data(repeating: 0, count: 4_000)
        .write(to: directory.appendingPathComponent("microphone-audio.f32"))

    let before = RecordingFolderLiveness.sample(in: directory)
    let after = RecordingFolderLiveness.sample(in: directory)

    #expect(!RecordingFolderLiveness.isGrowing(from: before, to: after))
}

@Test("Either track growing is enough")
func microphoneGrowthAloneIsLive() throws {
    let directory = try makeFolder("mic")
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(repeating: 0, count: 4_000)
        .write(to: directory.appendingPathComponent("system-audio.f32"))
    let mic = directory.appendingPathComponent("microphone-audio.f32")
    try Data(repeating: 0, count: 4_000).write(to: mic)

    let before = RecordingFolderLiveness.sample(in: directory)
    try Data(repeating: 0, count: 4_400).write(to: mic)
    let after = RecordingFolderLiveness.sample(in: directory)

    #expect(RecordingFolderLiveness.isGrowing(from: before, to: after))
}

@Test("A track appearing between samples is growth")
func aTrackAppearingIsGrowth() throws {
    // A capture that has just started has written one file and not yet the other. Absent-then-
    // present has to read as live, or the narrowest window in a recording's life is the one where
    // it is least protected.
    let directory = try makeFolder("appearing")
    defer { try? FileManager.default.removeItem(at: directory) }

    let before = RecordingFolderLiveness.sample(in: directory)
    try Data(repeating: 0, count: 4_000)
        .write(to: directory.appendingPathComponent("system-audio.f32"))
    let after = RecordingFolderLiveness.sample(in: directory)

    #expect(RecordingFolderLiveness.isGrowing(from: before, to: after))
}

@Test("A folder with no tracks at all is not live, and does not throw")
func emptyFolderIsNotLive() throws {
    let directory = try makeFolder("empty")
    defer { try? FileManager.default.removeItem(at: directory) }

    let before = RecordingFolderLiveness.sample(in: directory)
    let after = RecordingFolderLiveness.sample(in: directory)

    #expect(!RecordingFolderLiveness.isGrowing(from: before, to: after))
}

@Test("A track that shrinks is not treated as live")
func shrinkingIsNotLive() throws {
    // Nothing in the app truncates a track mid-capture, so this is a corrupt or externally edited
    // folder rather than a live one. Reading it as live would defer its recovery forever, which is
    // the one outcome worse than rebuilding it.
    let directory = try makeFolder("shrinking")
    defer { try? FileManager.default.removeItem(at: directory) }
    let track = directory.appendingPathComponent("system-audio.f32")
    try Data(repeating: 0, count: 8_000).write(to: track)

    let before = RecordingFolderLiveness.sample(in: directory)
    try Data(repeating: 0, count: 4_000).write(to: track)
    let after = RecordingFolderLiveness.sample(in: directory)

    #expect(!RecordingFolderLiveness.isGrowing(from: before, to: after))
}
