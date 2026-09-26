import Foundation
import Testing
@testable import WhisperCore

// F183 — the pasted link becomes a subprocess argument, so validation is a security boundary, not just
// input hygiene. These lock the flag-injection guard, scheme allow-list, YouTube detection, and
// playlist/channel detection.

@Test("Rejects a leading-dash URL as flag injection (F183)")
func rejectsFlagInjection() {
    #expect(throws: MediaSourceURL.ValidationError.flagInjection) {
        try MediaSourceURL.validate("--exec=echo pwned https://youtu.be/abc")
    }
}

@Test("Accepts only http/https schemes (F183)")
func rejectsNonHTTPSchemes() {
    for bad in ["file:///etc/passwd", "data:text/html,x", "javascript:alert(1)", "ftp://host/f"] {
        #expect(throws: MediaSourceURL.ValidationError.notHTTP) { try MediaSourceURL.validate(bad) }
    }
    #expect(throws: MediaSourceURL.ValidationError.empty) { try MediaSourceURL.validate("   ") }
}

@Test("Recognizes YouTube hosts and extracts the video id (F183)")
func recognizesYouTube() throws {
    let watch = try MediaSourceURL.validate("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s")
    #expect(watch.isYouTube)
    #expect(watch.videoID == "dQw4w9WgXcQ")
    #expect(!watch.isPlaylist)

    let short = try MediaSourceURL.validate("https://youtu.be/dQw4w9WgXcQ?t=42")
    #expect(short.isYouTube)
    #expect(short.videoID == "dQw4w9WgXcQ")

    let shorts = try MediaSourceURL.validate("https://youtube.com/shorts/abc123XYZ_-")
    #expect(shorts.isYouTube)
    #expect(shorts.videoID == "abc123XYZ_-")
}

@Test("A non-YouTube host validates as a generic web source (F183)")
func genericWebHost() throws {
    let parsed = try MediaSourceURL.validate("https://example.com/media/talk.mp4")
    #expect(!parsed.isYouTube)
    #expect(parsed.kind == MediaSource.webKind)
    #expect(parsed.host == "example.com")
    #expect(parsed.videoID == nil)
}

@Test("Detects playlist and channel URLs so the caller can refuse them (F183)")
func detectsPlaylistsAndChannels() throws {
    #expect(try MediaSourceURL.validate("https://youtube.com/watch?v=abc&list=PL123").isPlaylist)
    #expect(try MediaSourceURL.validate("https://www.youtube.com/playlist?list=PL123").isPlaylist)
    #expect(try MediaSourceURL.validate("https://www.youtube.com/channel/UC12345").isPlaylist)
    #expect(try MediaSourceURL.validate("https://www.youtube.com/@SomeCreator").isPlaylist)
    #expect(try !MediaSourceURL.validate("https://youtu.be/dQw4w9WgXcQ").isPlaylist)
}

// F495 — the channel/playlist heuristics are YouTube's, and they were applied to every host: TikTok's
// canonical single-video URL is `/@user/video/<id>` and a Mastodon or Threads post is `/@user/<id>`,
// so each was refused as "a playlist or channel". Other hosts rely on the always-passed --no-playlist.
@Test("A single video on another host is not refused as a playlist or channel (F495)")
func otherHostsAreNotJudgedByYouTubeChannelRules() throws {
    for single in [
        "https://www.tiktok.com/@scout2015/video/6718335390845095173",
        "https://mastodon.social/@Gargron/109311231234567890",
        "https://www.threads.net/@zuck/post/C1a2b3c4d5e",
        "https://example.com/c/talks/keynote.mp4",
        "https://example.com/watch?id=7&list=related",
    ] {
        let parsed = try MediaSourceURL.validate(single)
        #expect(!parsed.isPlaylist, "\(single)")
        #expect(parsed.kind == MediaSource.webKind)
    }
    // YouTube's own channel and playlist shapes are still refused.
    #expect(try MediaSourceURL.validate("https://m.youtube.com/@SomeCreator/videos").isPlaylist)
    #expect(try MediaSourceURL.validate("https://youtu.be/dQw4w9WgXcQ?list=PL123").isPlaylist)
}
