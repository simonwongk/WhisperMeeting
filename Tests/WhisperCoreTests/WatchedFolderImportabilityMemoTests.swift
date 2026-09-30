import Foundation
import Testing
@testable import WhisperCore

// F671 — `WatchedFolderMonitor` feeds the whole folder listing to `WatchedFolderInbox.ready(in:)` on
// the main actor every three seconds, and the inbox asked `ExternalFileIntake.isImportable` (a
// UTType lookup) of every file on every look. The verdict depends only on the URL being a file URL
// and on its `pathExtension`, so one lookup per distinct extension per look gives the same answer.
// These tests count the lookups instead of timing them: a clock makes "slow" a property of the host.

private final class CountingClassifier: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }

    func classify(_ url: URL) -> Bool {
        lock.lock(); count += 1; lock.unlock()
        return ExternalFileIntake.isImportable(url)
    }
}

private func entry(_ name: String, _ size: Int64, modified: TimeInterval = 0) -> WatchedFolderInbox.Entry {
    WatchedFolderInbox.Entry(url: URL(fileURLWithPath: "/inbox/\(name)"), size: size, modified: Date(timeIntervalSince1970: modified))
}

@Test("A look asks the importable question once per extension, not once per file (F671)")
func importabilityIsAskedOncePerExtensionPerLook() {
    let classifier = CountingClassifier()
    var inbox = WatchedFolderInbox(known: nil, isImportable: { classifier.classify($0) })
    // 2,000 files across three extensions, one of them in capitals: the memo is keyed by the
    // extension exactly as spelled, so three extensions are at most three lookups a look.
    let extensions = ["m4a", "txt", "MP3"]
    let listing = (0..<2_000).map { entry("clip-\($0).\(extensions[$0 % extensions.count])", 100) }

    #expect(inbox.ready(in: listing).isEmpty, "the first look is the baseline and imports nothing")
    let afterFirstLook = classifier.calls
    #expect(afterFirstLook <= extensions.count, "the first look classified \(afterFirstLook) files one by one")

    // A file arrives. It is still one more lookup at most per extension, and it is still found.
    let arrived = entry("new-recording.m4a", 500, modified: 9)
    var ready: [URL] = []
    for _ in 0..<3 { ready += inbox.ready(in: listing + [arrived]) }
    let steadyState = classifier.calls - afterFirstLook
    #expect(steadyState <= 3 * extensions.count, "three steady-state looks classified \(steadyState) files one by one")
    #expect(ready == [arrived.url], "the memo must not change which files are handed over")
}

@Test("Memoizing the importable verdict hands over exactly what a per-file lookup does (F671)")
func memoizedImportabilityMatchesPerFileLookup() {
    let referenceRule: (WatchedFolderInbox.Entry) -> Bool = { entry in
        !entry.url.lastPathComponent.hasPrefix(".") && ExternalFileIntake.isImportable(entry.url)
    }
    // The non-file URL comes first and has a recording's extension: a memo keyed only by extension
    // would record "m4a is not importable" from it and then drop every real `.m4a` after it.
    let notAFile = WatchedFolderInbox.Entry(
        url: URL(string: "https://example.com/remote.m4a")!, size: 100, modified: Date(timeIntervalSince1970: 0)
    )
    let first: [WatchedFolderInbox.Entry] = [
        notAFile,
        entry("a.m4a", 100), entry("b.M4A", 200), entry("notes.txt", 300), entry("README", 400),
        entry(".hidden.m4a", 500), entry("partial.m4a.part", 600), entry("empty.mp3", 0),
        entry("movie.mov", 700), entry("shout.MP3", 800),
    ]
    // Later looks: a file grows, one leaves, one arrives.
    let second = first.filter { $0.url.lastPathComponent != "movie.mov" }
        .map { $0.url.lastPathComponent == "a.m4a" ? entry("a.m4a", 150, modified: 1) : $0 }
        + [entry("later.wav", 900, modified: 2)]
    let looks = [first, second, second, second, second]

    // `known: [:]` — a previous run watched this folder and saw none of these, so all are new and
    // the looks actually hand files over, rather than only recording a baseline.
    var memoized = WatchedFolderInbox(known: [:])
    var reference = WatchedFolderInbox(known: [:])
    var handedOver: [URL] = []
    for (index, listing) in looks.enumerated() {
        let got = memoized.ready(in: listing)
        let expected = reference.ready(in: listing.filter(referenceRule))
        #expect(got == expected, "look \(index + 1) differs")
        #expect(memoized.snapshot == reference.snapshot, "look \(index + 1)'s snapshot differs")
        handedOver += got
    }
    // The comparison is only worth something if the looks handed over files at all, including one
    // whose extension differs only in case from another's.
    let names = Set(handedOver.map(\.lastPathComponent))
    #expect(names == ["a.m4a", "b.M4A", "shout.MP3", "later.wav"])
}
