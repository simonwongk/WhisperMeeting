import Foundation
import Testing
@testable import WhisperMeet

// F703 — the recording health tick read the volume's free space through one long-lived `URL`.
//
// `emitHealthSnapshot` runs once a second on `captureQueue` and passes `sessionDirectory` — the same
// `URL` for the whole recording — to `availableStorageBytes(at:)`. `URL.resourceValues(forKeys:)`
// answers from that instance's cache when it can (`NSURL.h:181`: "This method first checks if the URL
// object already caches the resource values. If so, it returns the cached resource values"), and the
// cache is cleared by itself only for a URL used from the MAIN thread, "the next time the main
// thread's run loop runs" (`NSURL.h:172`). A dispatch queue has no run loop, so the first second's
// figure was the figure for the whole recording, and the low-storage warning (F530) could not see the
// disk fill. Measured before the fix on this Mac, on a serial queue, with 512 MB written between two
// reads: same instance `155698570268` both times (delta 0); a fresh URL `155161678876`.
//
// The test changes what the file system answers for ONE `URL` instance without writing any data: the
// held path runs through a symlink, and retargeting the symlink from a temp directory to `/dev` moves
// the path from the data volume to devfs. A reader that trusts the instance's cache keeps the first
// volume's figure; a reader that asks the file system gets devfs's. The disk is never filled, and
// nothing is asserted about how much space this host has: only that the reader agrees with a fresh
// read made at the same moment.

private let importantUsageKey = URLResourceKey.volumeAvailableCapacityForImportantUsageKey

@Test("The health tick's free-space read follows the volume, not the URL's first answer (F703)")
func healthTickFreeSpaceReadIsNotFrozenByTheURLCache() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F703-\(UUID().uuidString)", isDirectory: true)
    let real = root.appendingPathComponent("real", isDirectory: true)
    let link = root.appendingPathComponent("link")
    try FileManager.default.createDirectory(
        at: real.appendingPathComponent("fd", isDirectory: true), withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    defer {
        // The link first, explicitly, so nothing here ever removes through it into /dev.
        try? FileManager.default.removeItem(at: link)
        try? FileManager.default.removeItem(at: root)
    }

    // One instance for the whole test, as `sessionDirectory` is one instance for a whole recording.
    let held = link.appendingPathComponent("fd", isDirectory: true)
    // A serial dispatch queue, as `captureQueue` is: no run loop ever turns on it.
    let queue = DispatchQueue(label: "F703.health-tick-stand-in")

    let first = queue.sync { AudioCaptureEngine.availableStorageBytes(at: held) }
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/dev"))
    let second = queue.sync { AudioCaptureEngine.availableStorageBytes(at: held) }
    let freshControl = queue.sync {
        (try? URL(fileURLWithPath: held.path, isDirectory: true).resourceValues(forKeys: [importantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    // The premise, required rather than assumed: the file system's answer for this path really did
    // change. Without it the test could not tell a cached read from a fresh one, and would pass or fail
    // for a reason that is not about the cache.
    try #require(freshControl != first,
                 "retargeting the link did not change the volume's answer (\(String(describing: first)))")
    #expect(second == freshControl,
            "the second tick read \(String(describing: second)), the first tick's \(String(describing: first)) again, while the file system now says \(String(describing: freshControl))")
}

@Test("The health tick reads free space only through the fresh reader (F703)")
func healthTickReadsFreeSpaceOnlyThroughTheFreshReader() throws {
    // `healthTickFreeSpaceReadIsNotFrozenByTheURLCache` drives the reader; this pins that the tick
    // uses it, and that no second read of the key in this file goes back through a held URL. The
    // timer's queue and the capture session it needs are not drivable headlessly.
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AudioCaptureEngine.swift")
    let tickReadsTheReader = source.contains("sessionDirectory.flatMap(Self.availableStorageBytes)")
    let readsOfTheKey = source.components(separatedBy: ".volumeAvailableCapacityForImportantUsageKey").count - 1
    #expect(tickReadsTheReader, "emitHealthSnapshot no longer reads free space through availableStorageBytes")
    #expect(readsOfTheKey == 1, "found \(readsOfTheKey) reads of the free-space key; only the fresh reader may read it")
}
