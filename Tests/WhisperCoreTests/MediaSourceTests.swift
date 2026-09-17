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
