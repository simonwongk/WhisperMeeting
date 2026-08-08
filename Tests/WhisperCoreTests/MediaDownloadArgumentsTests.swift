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

@Test("A hostile sub-language from site metadata cannot become a caption-selection pattern (F183)")
func sanitizesSubLangs() {
    // `--sub-langs` accepts regex and an `all` keyword, and the value comes from the site's metadata,
    // so anything but a plain code must not pass through — otherwise the pin that blocks auto-translated
    // tracks could be widened by the very metadata it is meant to constrain.
    #expect(MediaDownloadArguments.sanitizedSubLangs("en") == "en")
    #expect(MediaDownloadArguments.sanitizedSubLangs("zh-Hans") == "zh-Hans")
    #expect(MediaDownloadArguments.sanitizedSubLangs("all") == "all") // a literal code shape, still pinned below
    #expect(MediaDownloadArguments.sanitizedSubLangs("en.*") == "none")
    #expect(MediaDownloadArguments.sanitizedSubLangs("en,fr") == "none")
    #expect(MediaDownloadArguments.sanitizedSubLangs("") == "none")
}

@Test("Every vector ignores the user's yt-dlp config so the tested contract is what runs (F183)")
func ignoresUserConfig() {
    let url = "https://youtu.be/abc"
    #expect(MediaDownloadArguments.probe(url: url).contains("--ignore-config"))
    #expect(MediaDownloadArguments.download(url: url, intoDirectory: "/tmp/x").contains("--ignore-config"))
    #expect(MediaDownloadArguments.captions(url: url, intoDirectory: "/tmp/x", subLangs: "en").contains("--ignore-config"))
}

@Test("The extraction suppresses ffmpeg metadata so the WAV data chunk stays at the expected offset (F183)")
func extractionSuppressesMetadata() {
    let args = MediaDownloadArguments.download(url: "https://youtu.be/abc", intoDirectory: "/tmp/x")
    let recipe = try! #require(args.first { $0.contains("ExtractAudio+ffmpeg:") })
    // Without these, ffmpeg writes a LIST/INFO chunk between `fmt ` and `data`, and this app's WAV
    // readers take the data size from the fixed offset 40 — they would read the LIST size instead.
    #expect(recipe.contains("-map_metadata -1"))
    #expect(recipe.contains("-fflags +bitexact"))
    #expect(recipe.contains("-ar 16000"))
    #expect(recipe.contains("-ac 1"))
}

@Test("A flag-shaped URL still lands after -- so it can't be read as an option (F183)")
func flagShapedURLIsPositional() {
    // MediaSourceURL rejects a leading-dash URL, but -- is defense in depth if one slips through.
    let url = "https://youtu.be/-abc"
    #expect(endsWithSeparatedURL(MediaDownloadArguments.download(url: url, intoDirectory: "/tmp/x"), url))
}
