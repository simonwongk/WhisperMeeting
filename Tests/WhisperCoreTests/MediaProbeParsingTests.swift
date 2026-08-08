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
