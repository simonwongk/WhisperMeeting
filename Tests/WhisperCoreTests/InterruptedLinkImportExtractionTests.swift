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

@Test(
    "The installed ffmpeg turns a real WebM/Opus download into a finished 16 kHz mono WAV (F453)",
    .enabled(if: ProcessInfo.processInfo.environment["REAL_FFMPEG"] == "1")
)
func realFFmpegFinishesAnInterruptedWebM() async throws {
    let ffmpeg = try #require(MediaDownloadRuntime.findFFmpeg(), "REAL_FFMPEG=1 needs an installed ffmpeg")
    let (folder, download, _) = try makeInterruptedFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    // A 3 s Opus-in-WebM file, the format YouTube's bestaudio usually is (format 251).
    let make = Process()
    make.executableURL = ffmpeg
    make.arguments = ["-nostdin", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                      "-c:a", "libopus", download.path]
    try make.run()
    make.waitUntilExit()
    try #require(make.terminationStatus == 0, "could not make the WebM fixture")

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
