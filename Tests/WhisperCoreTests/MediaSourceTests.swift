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
