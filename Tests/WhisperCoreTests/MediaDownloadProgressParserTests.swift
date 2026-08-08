import Foundation
import Testing
@testable import WhisperCore

// F183 — parse real yt-dlp --newline progress lines into a fraction + ETA.

@Test("Parses a yt-dlp download line into fraction and ETA seconds (F183)")
func parsesDownloadLine() {
    var parser = MediaDownloadProgressParser()
    let progress = parser.consume("[download]  42.3% of 12.34MiB at 1.23MiB/s ETA 00:07\n")
    let p = try! #require(progress)
    #expect(abs((p.fractionCompleted ?? 0) - 0.423) < 0.0001)
    #expect(p.estimatedSecondsRemaining == 7)
}

@Test("Handles an hours ETA and a 100% completion line (F183)")
func parsesHoursAndComplete() {
    var parser = MediaDownloadProgressParser()
    let mid = parser.consume("[download]   5.0% of ~1.20GiB at 500KiB/s ETA 01:02:03\n")
    #expect(try! #require(mid).estimatedSecondsRemaining == 3723)
    let done = parser.consume("[download] 100% of 12.34MiB in 00:10\n")
    #expect(try! #require(done).fractionCompleted == 1.0)
}

@Test("Non-progress and unchanged lines yield nil (F183)")
func ignoresNoise() {
    var parser = MediaDownloadProgressParser()
    #expect(parser.consume("[youtube] Extracting URL: https://…\n") == nil)
    _ = parser.consume("[download]  10.0% of 5.00MiB at 1.00MiB/s ETA 00:04\n")
    // The exact same line again reports no new progress.
    #expect(parser.consume("[download]  10.0% of 5.00MiB at 1.00MiB/s ETA 00:04\n") == nil)
}
