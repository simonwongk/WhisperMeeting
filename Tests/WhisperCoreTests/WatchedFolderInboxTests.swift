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

// F493 — a writer that pauses for longer than the standard settle window (6s = two looks) must not
// be mistaken for a finished file, once this instance has actually SEEN it still streaming in — a
// single arrival-to-final growth step (the test above) stays fast, because that shape is
// indistinguishable from "already finished" and is the common case for small/local files.
@Test("A file caught growing more than once needs a longer quiet period before it is ready (F493)")
func repeatedlyGrowingFileNeedsLongerQuietPeriod() {
    var inbox = WatchedFolderInbox()
    _ = inbox.ready(in: [])
    // A multi-minute recording streaming in over a slow network share: several consecutive looks
    // each see a larger size, exactly what a real, still-in-progress transfer looks like.
    #expect(inbox.ready(in: [file("talk.mp3", 100)]).isEmpty, "arrival")
    #expect(inbox.ready(in: [file("talk.mp3", 200)]).isEmpty, "growth event 1")
    #expect(inbox.ready(in: [file("talk.mp3", 300)]).isEmpty, "growth event 2 — now flagged as still streaming")
    // The transfer stalls at 30%. The standard two-look window elapses...
    #expect(inbox.ready(in: [file("talk.mp3", 300)]).isEmpty, "unchanged once — not enough even for the short window")
    #expect(inbox.ready(in: [file("talk.mp3", 300)]).isEmpty,
            "unchanged twice would have been ready under the plain settledLooks rule — this is the F493 fix")
    // ...and the writer resumes, proving the file that would have been handed over above was
    // genuinely incomplete.
    #expect(inbox.ready(in: [file("talk.mp3", 900)]).isEmpty, "resumed — still not ready, and the size just changed again")
    // It finishes and goes quiet for the full extended window (four looks) before being trusted.
    #expect(inbox.ready(in: [file("talk.mp3", 900)]).isEmpty, "quiet look 1 of 4")
    #expect(inbox.ready(in: [file("talk.mp3", 900)]).isEmpty, "quiet look 2 of 4")
    #expect(inbox.ready(in: [file("talk.mp3", 900)]).isEmpty, "quiet look 3 of 4")
    #expect(inbox.ready(in: [file("talk.mp3", 900)]).map(\.lastPathComponent) == ["talk.mp3"],
            "quiet look 4 of 4 — ready, and only now, with the FINAL complete size")
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

// F645 — the F324 claim ("the first look is linear, not quadratic") used to be a wall-clock bound: 20,000
// files inside 5 s. It failed at 7.9–8.2 s on a loaded machine. Measured on the Mac it was diagnosed
// on, a first look over 20,000 files takes 1.0–1.6 s, nearly all of it in `ExternalFileIntake.isImportable`
// (a UTType lookup per file), not in any scan of the baseline — so the bound was measuring the host
// and that lookup, and a quadratic regression and a busy Mac looked the same to it. What the claim
// rests on is the data structure: a per-candidate lookup is only linear overall while the record it
// looks in is hashed. So the test pins that, derived from the type's own stored properties (a
// hand-written list would not notice a field added later), and checks the behaviour over a
// 2,000-file listing — with no clock in it. That is a guard on the structure, not a proof that every
// possible implementation is linear: nothing in `WatchedFolderInbox` counts its own operations.

/// The stored properties of `value` that are ordered collections (an `Array` or one of its kin),
/// looking through `Optional`. Named by label, so a failure says which field to look at. Decided from
/// the property's *type*, not its value, so an empty array or a nil optional array is still caught.
private func storedOrderedCollections(in value: Any) -> [String] {
    Mirror(reflecting: value).children.compactMap { child -> String? in
        var description = String(describing: type(of: child.value))
        while description.hasPrefix("Optional<"), description.hasSuffix(">") {
            description = String(description.dropFirst("Optional<".count).dropLast())
        }
        let isOrdered = ["Array<", "ContiguousArray<", "ArraySlice<"].contains { description.hasPrefix($0) }
        return isOrdered ? child.label : nil
    }
}

/// What F324's quadratic version kept: the baseline as an array, searched once per candidate.
private struct ScansABaselineArray {
    var baseline: [String] = []
    var known: [String]? = nil
    var handled: [String: Int] = [:]
}

private struct LooksUpInHashes {
    var known: [String: Int]? = nil
    var handled: Set<String> = []
    var didBaseline = false
}

@Test("The first look over a large folder is linear, not quadratic (F324)")
func firstLookOverALargeFolderIsLinear() {
    // The guard has to be able to fail: it must name the array fields of the quadratic shape and
    // none of the hashed one, or the check on the real type below would pass whatever it held.
    #expect(storedOrderedCollections(in: ScansABaselineArray()) == ["baseline", "known"])
    #expect(storedOrderedCollections(in: LooksUpInHashes()).isEmpty)

    var inbox = WatchedFolderInbox()
    #expect(!Mirror(reflecting: inbox).children.isEmpty, "the inbox exposes no stored state, so nothing was checked")
    #expect(
        storedOrderedCollections(in: inbox).isEmpty,
        "an ordered collection in the inbox's state is searched per candidate: use a Dictionary or a Set"
    )

    // Behaviour over a large listing, untimed. Every file the first look sees becomes baseline and
    // none is imported, and a second look over the same folder imports nothing either.
    let count = 2_000
    let listing = (0..<count).map { file("clip-\($0).m4a", 100, modified: TimeInterval($0)) }
    #expect(inbox.ready(in: listing).isEmpty)
    #expect(inbox.snapshot?.count == count, "the first look must record every file it saw as already there")
    #expect(inbox.ready(in: listing).isEmpty)
    #expect(inbox.snapshot?.count == count)
}
