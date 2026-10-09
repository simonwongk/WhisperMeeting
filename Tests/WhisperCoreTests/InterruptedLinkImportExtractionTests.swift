import Foundation
import Testing
@testable import WhisperCore

// F453 (review) — recovery finishes the audio extraction a link import was interrupted in, because a
// WebM/Opus download recovered as it is cannot be opened by AVFoundation and was listed as an
// Unverified Import whose message invited deleting the only complete copy.
//
// The process is driven by stand-in executables (a shell script, /usr/bin/false, a path that does not
// exist), so these hold on any Mac. The real ffmpeg run is the last test, enabled by REAL_FFMPEG=1.

private func makeInterruptedFolder() throws -> (folder: URL, download: URL, partial: URL) {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("F453-finish-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let download = folder.appendingPathComponent("recording.webm")
    try Data("the complete download".utf8).write(to: download)
    var partial = WAVWriter.wavData(from: [Float](repeating: 0.1, count: 8_000), sampleRate: 16_000)
    let placeholder = Data([0xFF, 0xFF, 0xFF, 0xFF])
    partial.replaceSubrange(4..<8, with: placeholder)
    let dataTag = try #require(partial.range(of: Data("data".utf8)))
    partial.replaceSubrange(dataTag.upperBound..<(dataTag.upperBound + 4), with: placeholder)
    let partialURL = folder.appendingPathComponent("recording.wav")
    try partial.write(to: partialURL)
    return (folder, download, partialURL)
}

/// A stand-in ffmpeg: writes `body` to the file named by its last argument (`file:<path>`), then
/// exits with `status`.
private func fakeFFmpeg(in folder: URL, writing body: String?, exiting status: Int) throws -> URL {
    let script = folder.appendingPathComponent("fake-ffmpeg.sh")
    let write = body.map { "printf '%s' '\($0)' > \"${out#file:}\"" } ?? ":"
    try """
    #!/bin/sh
    for out; do :; done
    \(write)
    exit \(status)
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
}

@Test("Recovery's conversion runs the import's own ffmpeg options (F453)")
func recoveryExtractionUsesTheImportsOptions() throws {
    let download = MediaDownloadArguments.download(url: "https://youtu.be/abc", intoDirectory: "/tmp/x")
    let recipe = try #require(download.first { $0.hasPrefix("ExtractAudio+ffmpeg:") })
    #expect(recipe == "ExtractAudio+ffmpeg:" + MediaDownloadArguments.extractionFFmpegArguments.joined(separator: " "))
    // The import's contract, unchanged by moving it into a constant.
    #expect(recipe == "ExtractAudio+ffmpeg:-ar 16000 -ac 1 -sample_fmt s16 -map_metadata -1 -fflags +bitexact")

    let finish = MediaDownloadArguments.finishExtraction(input: "/x/-recording.webm", output: "/x/out.wav")
    let options = MediaDownloadArguments.extractionFFmpegArguments
    let containsOptions = (0...(finish.count - options.count)).contains { Array(finish[$0..<($0 + options.count)]) == options }
    #expect(containsOptions, "\(finish)")
    #expect(finish.contains("-vn"))
    #expect(finish[(try #require(finish.firstIndex(of: "-i"))) + 1] == "file:/x/-recording.webm")
    #expect(finish.suffix(3) == ["-f", "wav", "file:/x/out.wav"])
}

@Test("A finished conversion replaces the half-written WAV and leaves the download as it was (F453)")
func aFinishedConversionReplacesThePartialWAV() async throws {
    let (folder, download, partial) = try makeInterruptedFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let ffmpeg = try fakeFFmpeg(in: folder, writing: "converted audio", exiting: 0)

    let result = try await InterruptedLinkImportExtraction.finish(download: download, ffmpeg: ffmpeg)

    #expect(result.standardizedFileURL == partial.standardizedFileURL)
    #expect(try String(contentsOf: result, encoding: .utf8) == "converted audio")
    #expect(try String(contentsOf: download, encoding: .utf8) == "the complete download")
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(InterruptedLinkImportExtraction.temporaryFilename).path))
}

@Test("A conversion that fails leaves the download and the half-written WAV, and no temp file (F453)")
func aFailedConversionTouchesNothing() async throws {
    // Exits non-zero having written nothing; exits non-zero having written half a file; exits zero
    // having written nothing.
    let runs: [(body: String?, status: Int)] = [(nil, 1), ("half a file", 1), (nil, 0)]
    for (body, status) in runs {
        let (folder, download, partial) = try makeInterruptedFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try Data(contentsOf: partial)
        let ffmpeg = try fakeFFmpeg(in: folder, writing: body, exiting: status)

        await #expect(throws: MediaDownloadError.extractionFailed) {
            try await InterruptedLinkImportExtraction.finish(download: download, ffmpeg: ffmpeg)
        }
        #expect(try Data(contentsOf: partial) == before, "the half-written WAV changed (\(String(describing: body)), \(status))")
        #expect(try String(contentsOf: download, encoding: .utf8) == "the complete download")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(InterruptedLinkImportExtraction.temporaryFilename).path))
    }
}

@Test("No ffmpeg, or one that cannot be started, reads as ffmpeg missing and touches nothing (F453)")
func noFFmpegIsFFmpegMissing() async throws {
    let (folder, download, partial) = try makeInterruptedFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let before = try Data(contentsOf: partial)
    for ffmpeg in [nil, URL(fileURLWithPath: "/nonexistent/ffmpeg")] as [URL?] {
        await #expect(throws: MediaDownloadError.ffmpegMissing) {
            try await InterruptedLinkImportExtraction.finish(download: download, ffmpeg: ffmpeg)
        }
    }
    #expect(try Data(contentsOf: partial) == before)
    #expect(FileManager.default.fileExists(atPath: download.path))
}

/// Writes `seconds` of a sine as Opus in WebM with the installed ffmpeg. Through the async runner
/// rather than `Process.waitUntilExit()`, which blocks a cooperative thread (F169).
private func makeOpusWebM(at url: URL, seconds: Int, ffmpeg: URL) async throws {
    let outcome = try await ProcessGroupRunner().run(
        executableURL: ffmpeg,
        arguments: ["-nostdin", "-y", "-loglevel", "error", "-f", "lavfi", "-i",
                    "sine=frequency=440:duration=\(seconds)", "-c:a", "libopus", url.path],
        environment: MediaDownloadClient.makeEnvironment(),
        stallTimeout: 0
    )
    try #require(outcome.exitStatus == 0, "could not make the WebM fixture: \(outcome.output)")
}

@Test(
    "The installed ffmpeg turns a real WebM/Opus download into a finished 16 kHz mono WAV (F453)",
    .enabled(if: ProcessInfo.processInfo.environment["REAL_FFMPEG"] == "1")
)
func realFFmpegFinishesAnInterruptedWebM() async throws {
    let ffmpeg = try #require(MediaDownloadRuntime.findFFmpeg(), "REAL_FFMPEG=1 needs an installed ffmpeg")
    let (folder, download, _) = try makeInterruptedFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    // A 3 s Opus-in-WebM file, the format YouTube's bestaudio usually is (format 251).
    try await makeOpusWebM(at: download, seconds: 3, ffmpeg: ffmpeg)

    let result = try await InterruptedLinkImportExtraction.finish(download: download, ffmpeg: ffmpeg)

    let duration = try #require(InterruptedRecordingRecovery.finalizedDuration(at: result), "the WAV is not finished")
    #expect(abs(duration - 3.0) < 0.1, "duration \(duration)")
    let header = try #require(WAVInspection.header(at: result))
    #expect(header.sampleRate == 16_000)
    #expect(header.channels == 1)
    #expect(header.bitsPerSample == 16)
    #expect(FileManager.default.fileExists(atPath: download.path), "the download was removed")
    #expect(InterruptedRecordingRecovery.finalizedRecording(in: folder)?.recordingURL.lastPathComponent == "recording.wav")
    print("REAL_FFMPEG: \(ffmpeg.path) → \(result.lastPathComponent), \(duration) s, \(header.sampleRate) Hz, \(header.channels) ch, \(header.bitsPerSample)-bit")
}

// MARK: - The time limit startup recovery runs this under

/// A stand-in for ffmpeg 8 whose input has stopped arriving: it prints a progress line every quarter
/// second and makes no progress, for about ten seconds, then writes its output and exits 0 — so a
/// time limit that is not enforced reads as a finished conversion. ffmpeg 8.1.2 was measured doing
/// the first part (sixteen identical `time=` reports in eight seconds), which is why the runner's
/// stall watchdog, reset by any output at all, cannot end it. It creates `started` first, so a test
/// can tell it is running.
private func stuckFFmpeg(in folder: URL) throws -> URL {
    let script = folder.appendingPathComponent("stuck-ffmpeg.sh")
    try """
    #!/bin/sh
    for out; do :; done
    : > "\(folder.path)/started"
    i=0
    while [ $i -lt 40 ]; do
      printf 'size=       0KiB time=00:00:06.39 bitrate= 255.3kbits/s speed=0.9x\\r' >&2
      sleep 0.25
      i=$((i + 1))
    done
    printf '%s' 'converted audio' > "${out#file:}"
    exit 0
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
}

@Test("A conversion still going at its time limit is stopped, whatever it prints, and touches nothing (F453)")
func aConversionPastItsTimeLimitIsStopped() async throws {
    // Within the limit nothing changes.
    do {
        let (folder, download, _) = try makeInterruptedFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ffmpeg = try fakeFFmpeg(in: folder, writing: "converted audio", exiting: 0)
        let result = try await InterruptedLinkImportExtraction.finish(download: download, ffmpeg: ffmpeg, timeLimit: 60)
        #expect(try String(contentsOf: result, encoding: .utf8) == "converted audio")
    }
    // Past it: printing progress does not keep it alive, and what was there stays as it was.
    let (folder, download, partial) = try makeInterruptedFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let before = try Data(contentsOf: partial)
    let ffmpeg = try stuckFFmpeg(in: folder)

    await #expect(throws: MediaDownloadError.extractionTimedOut(0.5)) {
        try await InterruptedLinkImportExtraction.finish(download: download, ffmpeg: ffmpeg, stallTimeout: 2, timeLimit: 0.5)
    }

    #expect(try Data(contentsOf: partial) == before, "the half-written WAV changed")
    #expect(try String(contentsOf: download, encoding: .utf8) == "the complete download")
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(InterruptedLinkImportExtraction.temporaryFilename).path))
}

@Test("A cancelled conversion is a cancellation, not a timeout, and touches nothing (F453)")
func aCancelledConversionIsNotATimeout() async throws {
    // Startup recovery leaves the folder for the next launch on a cancellation and lists the import
    // as unfinished on a timeout, so the two must not be confused.
    let (folder, download, partial) = try makeInterruptedFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let before = try Data(contentsOf: partial)
    let ffmpeg = try stuckFFmpeg(in: folder)
    let conversion = Task {
        try await InterruptedLinkImportExtraction.finish(download: download, ffmpeg: ffmpeg, timeLimit: 60)
    }
    // Cancelled once the stand-in runs, so the cancellation reaches the process and not the spawn.
    let started = folder.appendingPathComponent("started")
    let deadline = Date().addingTimeInterval(60)
    while !FileManager.default.fileExists(atPath: started.path), Date() < deadline {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    try #require(FileManager.default.fileExists(atPath: started.path), "the stand-in ffmpeg never started")

    conversion.cancel()

    await #expect(throws: CancellationError.self) { try await conversion.value }
    #expect(try Data(contentsOf: partial) == before, "the half-written WAV changed")
    #expect(try String(contentsOf: download, encoding: .utf8) == "the complete download")
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(InterruptedLinkImportExtraction.temporaryFilename).path))
}

@Test(
    "The installed ffmpeg, still converting at its time limit, is stopped and leaves no file behind (F453)",
    .enabled(if: ProcessInfo.processInfo.environment["REAL_FFMPEG"] == "1")
)
func realFFmpegPastItsTimeLimitIsStopped() async throws {
    // ffmpeg writes its trailer when it is stopped by SIGTERM, so the temp file it leaves has a
    // header that reads as finished; it must be removed, never renamed into place.
    let ffmpeg = try #require(MediaDownloadRuntime.findFFmpeg(), "REAL_FFMPEG=1 needs an installed ffmpeg")
    let (folder, download, partial) = try makeInterruptedFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let before = try Data(contentsOf: partial)
    // Ten minutes of audio: over a second to convert on an M3 Pro, so still running at 0.2 s.
    try await makeOpusWebM(at: download, seconds: 600, ffmpeg: ffmpeg)
    let downloadBytes = try Data(contentsOf: download)

    await #expect(throws: MediaDownloadError.extractionTimedOut(0.2)) {
        try await InterruptedLinkImportExtraction.finish(download: download, ffmpeg: ffmpeg, timeLimit: 0.2)
    }

    #expect(try Data(contentsOf: partial) == before, "the half-written WAV changed")
    #expect(try Data(contentsOf: download) == downloadBytes, "the download changed")
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(InterruptedLinkImportExtraction.temporaryFilename).path))
    print("REAL_FFMPEG: \(ffmpeg.path) stopped at the 0.2 s limit; download and half-written WAV untouched, no temp file")
}
