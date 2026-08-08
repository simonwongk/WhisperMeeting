import Foundation
import Testing
@testable import WhisperCore

// F183 — the yt-dlp argument vectors. Three invariants are security/correctness load-bearing:
// `--` before the URL, `--no-playlist` everywhere, and audio forced to WAV named `recording`.

private func endsWithSeparatedURL(_ args: [String], _ url: String) -> Bool {
    args.count >= 2 && args[args.count - 2] == "--" && args[args.count - 1] == url
}

@Test("Probe args dump JSON for a single item with the URL after -- (F183)")
func probeArgs() {
    let url = "https://youtu.be/abc"
    let args = MediaDownloadArguments.probe(url: url)
    #expect(args.contains("--dump-single-json"))
    #expect(args.contains("--no-playlist"))
    #expect(endsWithSeparatedURL(args, url))
}

@Test("Download args force WAV named recording, single item, URL after -- (F183)")
func downloadArgs() {
    let url = "https://youtu.be/abc"
    let args = MediaDownloadArguments.download(url: url, intoDirectory: "/tmp/rec")
    #expect(args.contains("--no-playlist"))
    #expect(args.contains("--extract-audio"))
    #expect(zip(args, args.dropFirst()).contains { $0 == "--audio-format" && $1 == "wav" })
    #expect(args.contains("/tmp/rec/recording.%(ext)s"))
    #expect(args.contains("--newline"))
    #expect(endsWithSeparatedURL(args, url))
}

@Test("Caption args pin the sub-language and skip the download, URL after -- (F183)")
func captionArgs() {
    let url = "https://youtu.be/abc"
    let args = MediaDownloadArguments.captions(url: url, intoDirectory: "/tmp/rec/", subLangs: "en")
    #expect(args.contains("--skip-download"))
    #expect(zip(args, args.dropFirst()).contains { $0 == "--sub-langs" && $1 == "en" })
    #expect(args.contains("--no-playlist"))
    #expect(endsWithSeparatedURL(args, url))
    // Directory already ending in "/" must not double the separator.
    #expect(args.contains("/tmp/rec/captions.%(ext)s"))
}

@Test("A flag-shaped URL still lands after -- so it can't be read as an option (F183)")
func flagShapedURLIsPositional() {
    // MediaSourceURL rejects a leading-dash URL, but -- is defense in depth if one slips through.
    let url = "https://youtu.be/-abc"
    #expect(endsWithSeparatedURL(MediaDownloadArguments.download(url: url, intoDirectory: "/tmp/x"), url))
}
