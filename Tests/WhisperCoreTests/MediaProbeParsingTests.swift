import Foundation
import Testing
@testable import WhisperCore

// F183 — the probe contract is checked without running yt-dlp, the LocalWhisperClientTests precedent.

@Test("Probe JSON maps onto MediaProbe, tolerating warning lines before it (F183)")
func parsesProbeJSON() throws {
    let output = """
    WARNING: [youtube] Falling back to a different client
    {"title":"Quarterly review","duration":3725.5,"uploader":"Acme","upload_date":"20260415",\
    "filesize_approx":41234567,"is_live":false,"language":"en"}
    """
    let probe = try MediaDownloadClient.parseProbe(output)
    #expect(probe.title == "Quarterly review")
    #expect(probe.durationSeconds == 3725.5)
    #expect(probe.uploader == "Acme")
    #expect(probe.approximateBytes == 41_234_567)
    #expect(probe.isLive == false)
    #expect(probe.language == "en")
    #expect(probe.uploadDate == MediaDownloadClient.parseUploadDate("20260415"))
}

@Test("A live stream and a channel-only uploader field are both read correctly (F183)")
func parsesLiveAndChannelFallback() throws {
    let output = #"{"title":"Live now","is_live":true,"channel":"Some Channel","duration":null}"#
    let probe = try MediaDownloadClient.parseProbe(output)
    #expect(probe.isLive)
    #expect(probe.uploader == "Some Channel") // falls back to `channel` when `uploader` is absent
    #expect(probe.durationSeconds == nil)
}

@Test("Unreadable probe output throws rather than inventing metadata (F183)")
func rejectsUnreadableProbe() {
    #expect(throws: MediaDownloadError.unreadableProbe) {
        try MediaDownloadClient.parseProbe("ERROR: Unsupported URL")
    }
}

@Test("The download environment reaches the network and finds Homebrew ffmpeg (F183)")
func downloadEnvironmentIsNetworkCapable() {
    let environment = MediaDownloadClient.makeEnvironment(
        base: ["PATH": "/usr/bin:/bin", "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1"]
    )
    #expect(environment["PATH"]?.contains("/opt/homebrew/bin") == true)
    // The transcription clients' offline pins must NOT leak into a downloader (Trap 13).
    #expect(environment["HF_HUB_OFFLINE"] == nil)
    #expect(environment["TRANSFORMERS_OFFLINE"] == nil)
}

// F495 follow-up — F495 stopped judging other hosts by YouTube's URL shapes, which also let through
// links that really are playlists: a TikTok profile (`/@user`), a youtube-nocookie `videoseries`
// embed. `--no-playlist` does not cover them; yt-dlp applies it only "if the URL refers to a video
// and a playlist". Such a probe reports `_type` `playlist` (or `multi_video`) with no duration or
// size, so the long-media confirmation and the storage guard had nothing to check. The probe is
// where yt-dlp says what the link is, for every host, so the refusal is there.

/// A stand-in `yt-dlp` that prints `json` as its probe output and exits 0.
private func fakeDownloader(printing json: String) throws -> (client: MediaDownloadClient, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("F495-probe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let payload = directory.appendingPathComponent("probe.json")
    try json.write(to: payload, atomically: true, encoding: .utf8)
    let script = directory.appendingPathComponent("yt-dlp")
    try "#!/bin/sh\ncat '\(payload.path)'\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return (MediaDownloadClient(executableURL: script), directory)
}

@Test("A probe that yt-dlp reports as a playlist is refused on any host (F495)")
func probeRefusesAPlaylistResult() async throws {
    for type in ["playlist", "multi_video"] {
        let fake = try fakeDownloader(printing: #"{"_type":"\#(type)","id":"MS4wLjABAAAA","title":"scout2015","entries":[]}"#)
        defer { try? FileManager.default.removeItem(at: fake.directory) }
        await #expect(throws: MediaDownloadError.playlistNotSupported) {
            _ = try await fake.client.probe(url: "https://www.tiktok.com/@scout2015")
        }
    }
}

@Test("A single-video probe is still accepted, with or without _type (F495 control)")
func probeAcceptsASingleVideo() async throws {
    // yt-dlp's own JSON always carries `_type` ("video" for one item); older fixtures and other
    // tools may omit it, and an absent type is not a playlist.
    for json in [
        #"{"_type":"video","title":"One clip","duration":42,"filesize_approx":1000}"#,
        #"{"title":"One clip","duration":42,"filesize_approx":1000}"#,
    ] {
        let fake = try fakeDownloader(printing: json)
        defer { try? FileManager.default.removeItem(at: fake.directory) }
        let probe = try await fake.client.probe(url: "https://www.tiktok.com/@scout2015/video/6718335390845095173")
        #expect(probe.title == "One clip")
        #expect(probe.durationSeconds == 42)
    }
}
