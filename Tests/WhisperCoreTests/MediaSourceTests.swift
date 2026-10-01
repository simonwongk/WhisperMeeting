import Foundation
import Testing
@testable import WhisperCore

// F183 — provenance value. `kind` is a String for forward-compatibility (an unknown enum value would
// throw and fail the whole meetings index to decode); the suggested tag is length-capped.

@Test("MediaSource round-trips through Codable and reports YouTube + suggested tag (F183)")
func mediaSourceRoundTrips() throws {
    let source = MediaSource(
        kind: MediaSource.youTubeKind, pageURL: "https://youtu.be/abc", host: "youtu.be",
        videoID: "abc", uploader: "Chan", uploadDate: nil, fetchedAt: Date(timeIntervalSince1970: 1_000)
    )
    #expect(source.isYouTube)
    #expect(source.suggestedTag == "YouTube")

    let data = try JSONEncoder().encode(source)
    let decoded = try JSONDecoder().decode(MediaSource.self, from: data)
    #expect(decoded == source)
}

@Test("An unknown future kind still decodes (String, not enum) and the web tag is host-capped (F183)")
func unknownKindDecodes() throws {
    // A newer build could write a kind this build has never heard of; it must not fail to decode.
    let json = #"{"kind":"vimeo","pageURL":"https://vimeo.com/1","host":"vimeo.com","fetchedAt":0}"#
    let decoded = try JSONDecoder().decode(MediaSource.self, from: Data(json.utf8))
    #expect(decoded.kind == "vimeo")
    #expect(!decoded.isYouTube)

    let longHost = String(repeating: "a", count: 60) + ".com"
    let web = MediaSource(kind: MediaSource.webKind, pageURL: "x", host: longHost, fetchedAt: Date(timeIntervalSince1970: 0))
    #expect(web.suggestedTag.count <= MeetingTags.maxLength)
}

// MARK: - F308: the sidecar was written and never read

@Test("The sidecar reads back exactly what the import path wrote (F308)")
func sidecarReadsBackWhatTheImportWrote() throws {
    // Written the way `importFromURL` writes it — a default `JSONEncoder`, straight to
    // `sidecarFilename` — rather than through a helper of this test's own, so a change to the
    // writer's date strategy that the reader does not follow fails here.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MediaSourceSidecar-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = MediaSource(
        kind: MediaSource.youTubeKind,
        pageURL: "https://www.youtube.com/watch?v=kestrel42",
        host: "youtube.com",
        videoID: "kestrel42",
        uploader: "Fairhaven Talks",
        uploadDate: Date(timeIntervalSince1970: 1_750_000_000),
        fetchedAt: Date(timeIntervalSince1970: 1_758_000_000)
    )
    try JSONEncoder().encode(source)
        .write(to: directory.appendingPathComponent(MediaSource.sidecarFilename))

    #expect(MediaSource.read(in: directory) == source)
}

@Test("A missing or corrupt sidecar reads as nil, never as a failure (F308)")
func unreadableSidecarIsNil() throws {
    // The rule `RecordingSessionSidecar.read` already follows: the sidecar is written best-effort
    // (`try?`), so recovery cannot depend on it and must not be failed by it.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MediaSourceSidecarBad-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(MediaSource.read(in: directory) == nil)

    try Data("{ \"kind\": \"youtube\", \"pageURL\": ".utf8)
        .write(to: directory.appendingPathComponent(MediaSource.sidecarFilename))
    #expect(MediaSource.read(in: directory) == nil)
}

// MARK: - F497: the provenance link is re-checked before it can be opened

// The scheme check ran only at import (`MediaSourceURL.validate`). The meeting header built its Link
// from the persisted `pageURL` — the index, or `source.json` read back by recovery — under the
// separately stored `host`, so a restored or hand-edited record could put a `file:` URL behind a
// "youtube.com" label. `provenanceLink` is what the header may open.

private func storedSource(pageURL: String, host: String = "youtube.com") -> MediaSource {
    MediaSource(
        kind: MediaSource.youTubeKind, pageURL: pageURL, host: host,
        fetchedAt: Date(timeIntervalSince1970: 0)
    )
}

@Test("A stored pageURL that is not an http(s) link gives no link to open, whatever host labels it (F497)")
func provenanceLinkRefusesWhatImportWouldHaveRefused() {
    let refused: [String] = [
        "file:///Users/x/Downloads/payload.app",
        "javascript:alert(1)",
        "data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==",
        "smb://host/share",
        "ssh://h",
        "x-apple.systempreferences:com.apple.preference.security",
        "-https://www.youtube.com/watch?v=abc",
        "https://www.youtube.com/watch?v=abc\u{0}file:///etc/passwd",
        "https:///no-host",
        "",
    ]
    for pageURL in refused {
        let link = storedSource(pageURL: pageURL).provenanceLink
        #expect(link == nil, "\(pageURL.debugDescription) gave \(String(describing: link))")
    }
}

@Test("The link's label is the host of the URL it opens, never the separately stored host (F497)")
func provenanceLinkLabelIsTheHostItOpens() throws {
    let elsewhere = try #require(storedSource(pageURL: "https://evil.example/watch?v=1").provenanceLink)
    #expect(elsewhere.label == "evil.example")
    #expect(elsewhere.url.absoluteString == "https://evil.example/watch?v=1")

    // A userinfo that reads like a host: the page is on evil.example, so that is the label.
    let userinfo = try #require(
        storedSource(pageURL: "https://youtube.com@evil.example/watch?v=1").provenanceLink
    )
    #expect(userinfo.label == "evil.example")
}

@Test("A link the import wrote opens its page under the host the import stored (F497)")
func provenanceLinkKeepsAGenuineImport() throws {
    // Built the way `importFromURL` builds it: from `MediaSourceURL.validate`'s result.
    let parsed = try MediaSourceURL.validate("https://www.youtube.com/watch?v=abc")
    let source = MediaSource(
        kind: parsed.kind, pageURL: parsed.url, host: parsed.host, videoID: parsed.videoID,
        fetchedAt: Date(timeIntervalSince1970: 0)
    )
    let link = try #require(source.provenanceLink)
    #expect(link.url == URL(string: "https://www.youtube.com/watch?v=abc"))
    #expect(link.label == "www.youtube.com")
    #expect(link.label == source.host)

    let web = try #require(storedSource(pageURL: "http://Example.COM/talk", host: "example.com").provenanceLink)
    #expect(web.label == "example.com")
    #expect(web.url.scheme?.lowercased() == "http")
}
