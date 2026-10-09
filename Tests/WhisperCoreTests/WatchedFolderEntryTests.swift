import Foundation
import Testing
@testable import WhisperCore

// F716 — a watched-folder look runs `WatchedFolderInbox.ready(in:)` on the main actor every three
// seconds over the whole listing, and most of its time over a large folder went on the entry's `URL`
// building its name, extension and path as new strings on every call. An entry now works those out
// once, when `WatchedFolderMonitor.listing(at:)` makes it off the main actor. The time is measured,
// not asserted (a clock makes "slow" a property of the host); this pins that what the look reads is
// what the URL says, so the stored values cannot come to disagree with the URL they were taken from.

@Test("An entry carries its URL's path, extension and hidden name, as the URL itself gives them (F716)")
func watchedFolderEntryCarriesWhatItsURLSays() throws {
    let urls = [
        URL(fileURLWithPath: "/inbox/call.m4a"),
        URL(fileURLWithPath: "/inbox/Call.WAV"),
        URL(fileURLWithPath: "/inbox/.hidden.mp3"),
        URL(fileURLWithPath: "/inbox/no-extension"),
        URL(fileURLWithPath: "/inbox/two.dots.mov"),
        URL(fileURLWithPath: "/in box/with space é.m4a"),
        try #require(URL(string: "https://example.com/talk.mp3")),
    ]
    for url in urls {
        let entry = WatchedFolderInbox.Entry(url: url, size: 1, modified: Date(timeIntervalSince1970: 0))
        #expect(entry.path == url.path, "\(url)")
        #expect(entry.pathExtension == url.pathExtension, "\(url)")
        #expect(entry.isHidden == url.lastPathComponent.hasPrefix("."), "\(url)")
    }
}

@Test("A hidden file is still passed over, read from the entry rather than its URL (F716)")
func watchedFolderStillSkipsHiddenFiles() {
    var inbox = WatchedFolderInbox(known: [:])
    let hidden = WatchedFolderInbox.Entry(
        url: URL(fileURLWithPath: "/inbox/.partial.m4a"), size: 10, modified: Date(timeIntervalSince1970: 1)
    )
    let shown = WatchedFolderInbox.Entry(
        url: URL(fileURLWithPath: "/inbox/call.m4a"), size: 10, modified: Date(timeIntervalSince1970: 1)
    )
    var handedOver: [URL] = []
    for _ in 0..<(WatchedFolderInbox.settledLooks + 2) {
        handedOver += inbox.ready(in: [hidden, shown])
    }
    #expect(handedOver == [shown.url])
}
