import Foundation
import Testing
@testable import WhisperCore

// F318 — an opt-in folder whose new recordings are imported. The rule that matters is when a file
// is *finished*: a recorder or a sync client writes for minutes, and importing a half-written file
// produces a truncated meeting that looks complete.
//
// F320 — and the rule for *arrival* is a listing, not a clock. `contentModificationDate` is the
// content's age, not when it landed in this folder, and every ordinary way of adding a file a user
// already has (a Finder copy, `cp -p`, `ditto`, unzip, AirDrop, a Time Machine restore) preserves
// it. The inbox therefore remembers the files it has already handled, and anything absent from that
// record is new whatever its dates say.

private func file(_ name: String, _ size: Int64, modified: TimeInterval = 0) -> WatchedFolderInbox.Entry {
    WatchedFolderInbox.Entry(url: URL(fileURLWithPath: "/inbox/\(name)"), size: size, modified: Date(timeIntervalSince1970: modified))
}

private func version(_ size: Int64, modified: TimeInterval = 0) -> WatchedFolderInbox.Version {
    WatchedFolderInbox.Version(size: size, modified: Date(timeIntervalSince1970: modified))
}

@Test("What was already in the folder when watching began is never imported (F318)")
func existingFilesAreNotImported() {
    var inbox = WatchedFolderInbox()
    #expect(inbox.ready(in: [file("old.m4a", 100)]).isEmpty)
    #expect(inbox.ready(in: [file("old.m4a", 100)]).isEmpty)
    #expect(inbox.ready(in: [file("old.m4a", 100)]).isEmpty)
}

@Test("A new file is imported once it has stopped changing for two looks, and only once (F318)")
func newFileIsImportedWhenSettled() {
    var inbox = WatchedFolderInbox()
    _ = inbox.ready(in: [])
    #expect(inbox.ready(in: [file("call.m4a", 10)]).isEmpty, "first sight")
    #expect(inbox.ready(in: [file("call.m4a", 50)]).isEmpty, "still growing")
    #expect(inbox.ready(in: [file("call.m4a", 50)]).isEmpty, "unchanged once is not enough")
    #expect(inbox.ready(in: [file("call.m4a", 50)]).map(\.lastPathComponent) == ["call.m4a"])
    #expect(inbox.ready(in: [file("call.m4a", 50)]).isEmpty, "never twice")
}

@Test("Empty files, non-recordings and hidden or in-progress downloads are ignored (F318)")
func nonRecordingsAreIgnored() {
    var inbox = WatchedFolderInbox()
    _ = inbox.ready(in: [])
    let listing = [file("empty.wav", 0), file("notes.pdf", 10), file(".hidden.m4a", 10), file("movie.mp4.download", 10), file("ok.wav", 10)]
    for _ in 0..<3 { _ = inbox.ready(in: listing) }
    #expect(inbox.ready(in: listing).isEmpty)
    var again = WatchedFolderInbox(); _ = again.ready(in: [])
    var seen: [String] = []
    for _ in 0..<4 { seen += again.ready(in: listing).map(\.lastPathComponent) }
    #expect(seen == ["ok.wav"])
}

@Test("A file replaced by a different recording under the same name is a new file (F318)")
func replacedFileIsNew() {
    var inbox = WatchedFolderInbox()
    _ = inbox.ready(in: [])
    for _ in 0..<3 { _ = inbox.ready(in: [file("daily.m4a", 50, modified: 1)]) }
    var seen = 0
    for _ in 0..<4 { seen += inbox.ready(in: [file("daily.m4a", 80, modified: 2)]).count }
    #expect(seen == 1)
}

@Test("A recording dropped while the app was closed is imported at the next launch (F318)")
func filesFromWhileTheAppWasClosedAreNew() {
    var inbox = WatchedFolderInbox(known: ["/inbox/before.m4a": version(10, modified: 50)])
    let listing = [file("before.m4a", 10, modified: 50), file("while-closed.m4a", 10, modified: 150)]
    var seen: [String] = []
    for _ in 0..<4 { seen += inbox.ready(in: listing).map(\.lastPathComponent) }
    #expect(seen == ["while-closed.m4a"])
}

@Test("A recording copied in with its original date is new, because arrival is not modification (F320)")
func copiedInFileKeepsItsOldDateAndIsStillNew() {
    // Every ordinary copy preserves mtime, so this file is *older* than everything already there.
    var inbox = WatchedFolderInbox(known: ["/inbox/before.m4a": version(10, modified: 5_000)])
    let listing = [file("before.m4a", 10, modified: 5_000), file("from-2019.m4a", 10, modified: 1)]
    var seen: [String] = []
    for _ in 0..<4 { seen += inbox.ready(in: listing).map(\.lastPathComponent) }
    #expect(seen == ["from-2019.m4a"])
}

@Test("A known file whose contents changed while the app was closed is new again (F320)")
func knownFileThatChangedWhileClosedIsNew() {
    var inbox = WatchedFolderInbox(known: ["/inbox/daily.m4a": version(10, modified: 5)])
    let listing = [file("daily.m4a", 90, modified: 9)]
    var seen: [String] = []
    for _ in 0..<4 { seen += inbox.ready(in: listing).map(\.lastPathComponent) }
    #expect(seen == ["daily.m4a"])
}

@Test("The snapshot leaves out a file that is still settling, so a quit mid-copy loses nothing (F320)")
func snapshotExcludesFilesStillSettling() {
    var inbox = WatchedFolderInbox()
    #expect(inbox.snapshot == nil, "nothing is known until the first look has been taken")
    _ = inbox.ready(in: [file("was-here.m4a", 100)])
    #expect(inbox.snapshot?.keys.sorted() == ["/inbox/was-here.m4a"])

    _ = inbox.ready(in: [file("was-here.m4a", 100), file("call.m4a", 10, modified: 500)])
    #expect(inbox.snapshot?.keys.sorted() == ["/inbox/was-here.m4a"], "seen but not handed over")
    _ = inbox.ready(in: [file("was-here.m4a", 100), file("call.m4a", 10, modified: 500)])
    _ = inbox.ready(in: [file("was-here.m4a", 100), file("call.m4a", 10, modified: 500)])
    #expect(inbox.snapshot?.keys.sorted() == ["/inbox/call.m4a", "/inbox/was-here.m4a"], "handed over, so it is known")
}

@Test("A file that leaves the folder leaves the snapshot, so it is new if it comes back (F320)")
func snapshotForgetsDeletedFiles() {
    var inbox = WatchedFolderInbox()
    _ = inbox.ready(in: [file("old.m4a", 100)])
    #expect(inbox.snapshot?.keys.sorted() == ["/inbox/old.m4a"])
    _ = inbox.ready(in: [])
    #expect(inbox.snapshot?.isEmpty == true)
}

@Test("The first look over a large folder is linear, not quadratic (F324)")
func firstLookOverALargeFolderIsLinear() {
    // 20,000 files is a plausible Downloads folder. The quadratic version — a linear scan of the
    // baseline array per candidate — is ~4x10^8 `Entry` comparisons and takes minutes; the linear
    // one is milliseconds. Any bound in between separates them.
    let listing = (0..<20_000).map { file("clip-\($0).m4a", 100, modified: TimeInterval($0)) }
    var inbox = WatchedFolderInbox()
    let started = Date()
    #expect(inbox.ready(in: listing).isEmpty)
    #expect(Date().timeIntervalSince(started) < 5, "the first look must not scan the baseline per candidate")
}
