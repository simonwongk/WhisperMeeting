import Foundation
import Testing
@testable import WhisperCore

// F318 — an opt-in folder whose new recordings are imported. The rule that matters is when a file
// is *finished*: a recorder or a sync client writes for minutes, and importing a half-written file
// produces a truncated meeting that looks complete.

private func file(_ name: String, _ size: Int64, modified: TimeInterval = 0) -> WatchedFolderInbox.Entry {
    WatchedFolderInbox.Entry(url: URL(fileURLWithPath: "/inbox/\(name)"), size: size, modified: Date(timeIntervalSince1970: modified))
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
    var inbox = WatchedFolderInbox(lastLook: Date(timeIntervalSince1970: 100))
    let listing = [file("before.m4a", 10, modified: 50), file("while-closed.m4a", 10, modified: 150)]
    var seen: [String] = []
    for _ in 0..<4 { seen += inbox.ready(in: listing).map(\.lastPathComponent) }
    #expect(seen == ["while-closed.m4a"])
}

@Test("A file seen but not yet settled holds back the saved last-look date (F318)")
func unsettledFileHoldsBackTheLastLook() {
    var inbox = WatchedFolderInbox()
    _ = inbox.ready(in: [])
    #expect(inbox.oldestUnsettled == nil)
    _ = inbox.ready(in: [file("call.m4a", 10, modified: 500)])
    #expect(inbox.oldestUnsettled == Date(timeIntervalSince1970: 500))
    _ = inbox.ready(in: [file("call.m4a", 10, modified: 500)])
    _ = inbox.ready(in: [file("call.m4a", 10, modified: 500)])
    #expect(inbox.oldestUnsettled == nil, "handed over, so the date may move on")
}
