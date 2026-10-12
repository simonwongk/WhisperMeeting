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

/// Every conversion temp file in `folder`: this build's one-per-run names and the single
/// `recording.extracting.wav` earlier builds wrote (F945).
private func temporaryFiles(in folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        .filter(InterruptedLinkImportExtraction.isTemporaryFile(named:))
        .sorted()
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
    #expect(temporaryFiles(in: folder).isEmpty, "a temp file was left: \(temporaryFiles(in: folder))")
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
        #expect(temporaryFiles(in: folder).isEmpty, "a temp file was left: \(temporaryFiles(in: folder))")
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

/// A stand-in for ffmpeg 8 whose input has stopped arriving: it writes the first part of its output,
/// then prints a progress line every quarter second and makes no progress, for about ten seconds, then
/// writes the rest and exits 0 — so a time limit that is not enforced reads as a finished conversion.
/// ffmpeg 8.1.2 was measured doing the middle part (sixteen identical `time=` reports in eight
/// seconds), which is why the runner's stall watchdog, reset by any output at all, cannot end it. The
/// first part is there because a stopped ffmpeg leaves a temp file — SIGTERM even finishes its header
/// (review of F453 round 2, finding 2) — and only a temp file that exists can be wrongly renamed into
/// place. It creates `started` once that part is written, so a test can tell it is running.
private func stuckFFmpeg(in folder: URL) throws -> URL {
    let script = folder.appendingPathComponent("stuck-ffmpeg.sh")
    try """
    #!/bin/sh
    for out; do :; done
    printf '%s' 'part of a conversion' > "${out#file:}"
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

    // Precondition: the stopped run had written part of its output, so there was a temp file that a
    // wrong ending could have renamed over the half-written WAV.
    try #require(FileManager.default.fileExists(atPath: folder.appendingPathComponent("started").path),
                 "the stand-in never wrote the first part of its output")
    #expect(try Data(contentsOf: partial) == before, "the half-written WAV changed")
    #expect(try String(contentsOf: download, encoding: .utf8) == "the complete download")
    #expect(temporaryFiles(in: folder).isEmpty, "a temp file was left: \(temporaryFiles(in: folder))")
}

/// A stand-in for ffmpeg 8.1.2 whose input read is blocked: it ignores SIGTERM, writes the first part
/// of its output, prints a progress line every quarter second and makes no progress, and after about
/// ten seconds marks that it ran to its own end, writes the rest and exits 0. ffmpeg was measured
/// doing this with recovery's own vector reading a FIFO whose writer had stopped (review of F453
/// round 2): still running 17.3 s after one SIGTERM, gone 2.1 s after a SIGKILL. The first part is
/// the temp file a stopped run leaves, which must be removed and never renamed into place. It
/// creates `started` once its trap is set and that part is written.
private func sigtermIgnoringFFmpeg(in folder: URL) throws -> (script: URL, ranToItsEnd: URL) {
    let script = folder.appendingPathComponent("sigterm-ignoring-ffmpeg.sh")
    let ranToItsEnd = folder.appendingPathComponent("ran-to-its-end")
    try """
    #!/bin/sh
    for out; do :; done
    trap '' TERM
    printf '%s' 'part of a conversion' > "${out#file:}"
    : > "\(folder.path)/started"
    i=0
    while [ $i -lt 40 ]; do
      printf 'size=     199KiB time=00:00:06.39 bitrate= 255.3kbits/s speed=0.9x\\r' >&2
      sleep 0.25
      i=$((i + 1))
    done
    : > "\(ranToItsEnd.path)"
    printf '%s' 'converted audio' > "${out#file:}"
    exit 0
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return (script, ranToItsEnd)
}

@Test("A conversion that ignores SIGTERM is still stopped at its time limit, and touches nothing (F453)")
func aConversionIgnoringSIGTERMIsStoppedAtItsLimit() async throws {
    // The limit used to send one SIGTERM and then wait, without a bound, for the process to exit —
    // which ffmpeg with a blocked read does not do, so the launch waited for it indefinitely.
    let (folder, download, partial) = try makeInterruptedFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let before = try Data(contentsOf: partial)
    let (ffmpeg, ranToItsEnd) = try sigtermIgnoringFFmpeg(in: folder)

    await #expect(throws: MediaDownloadError.extractionTimedOut(0.5)) {
        try await InterruptedLinkImportExtraction.finish(download: download, ffmpeg: ffmpeg, stallTimeout: 2, timeLimit: 0.5)
    }

    // No clock here: a stop the stand-in can ignore lets it run its ten seconds and leave this file.
    #expect(!FileManager.default.fileExists(atPath: ranToItsEnd.path), "the conversion ran to its own end: the limit did not stop it")
    try #require(FileManager.default.fileExists(atPath: folder.appendingPathComponent("started").path),
                 "the stand-in never wrote the first part of its output")
    #expect(try Data(contentsOf: partial) == before, "the half-written WAV changed")
    #expect(try String(contentsOf: download, encoding: .utf8) == "the complete download")
    #expect(temporaryFiles(in: folder).isEmpty, "a temp file was left: \(temporaryFiles(in: folder))")
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
    #expect(temporaryFiles(in: folder).isEmpty, "a temp file was left: \(temporaryFiles(in: folder))")
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
    #expect(temporaryFiles(in: folder).isEmpty, "a temp file was left: \(temporaryFiles(in: folder))")
    print("REAL_FFMPEG: \(ffmpeg.path) stopped at the 0.2 s limit; download and half-written WAV untouched, no temp file")
}

/// Set when a background run has returned.
private final class Finished: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func mark() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

@Test(
    "The installed ffmpeg, its input read blocked, is stopped at its time limit, not when the input closes (F453)",
    .enabled(if: ProcessInfo.processInfo.environment["REAL_FFMPEG"] == "1")
)
func realFFmpegWithItsInputStuckIsStoppedAtItsLimit() async throws {
    // The download is a FIFO that delivers the first 150 KB of a real WebM and is then held open, so
    // ffmpeg blocks in its read: the shape in which one SIGTERM does not stop it.
    let ffmpeg = try #require(MediaDownloadRuntime.findFFmpeg(), "REAL_FFMPEG=1 needs an installed ffmpeg")
    let (folder, download, partial) = try makeInterruptedFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let before = try Data(contentsOf: partial)
    let source = folder.appendingPathComponent("source.webm")
    try await makeOpusWebM(at: source, seconds: 60, ffmpeg: ffmpeg)
    try FileManager.default.removeItem(at: download)
    try #require(mkfifo(download.path, 0o600) == 0, "could not make the FIFO")

    let writer = ProcessGroupRunner()
    let writerDone = Finished()
    Task {
        _ = try? await writer.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exec > \"$1\"; head -c 150000 \"$2\"; sleep 15", "sh", download.path, source.path],
            environment: ["PATH": "/usr/bin:/bin"],
            stallTimeout: 0
        )
        writerDone.mark()
    }
    defer { writer.cancel() }

    await #expect(throws: MediaDownloadError.extractionTimedOut(1)) {
        try await InterruptedLinkImportExtraction.finish(download: download, ffmpeg: ffmpeg, timeLimit: 1)
    }

    // The input is still held open, so what ended ffmpeg was the limit, not the end of its input.
    #expect(!writerDone.isSet, "ffmpeg ran until its input closed: the limit did not stop it")
    #expect(try Data(contentsOf: partial) == before, "the half-written WAV changed")
    #expect(temporaryFiles(in: folder).isEmpty, "a temp file was left: \(temporaryFiles(in: folder))")
    print("REAL_FFMPEG: \(ffmpeg.path) with its read blocked: the conversion returned with its input \(writerDone.isSet ? "closed" : "still held open")")
}

// MARK: - Two conversions of one folder (F945)

/// Polls `condition` until it holds or 30 s pass; the caller `#require`s the result.
private func eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(30)
    while !condition() {
        guard Date() < deadline else { return false }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return true
}

/// A stand-in ffmpeg for one of two conversions racing over a folder. It writes `first` to its
/// output, creates `<name>-wrote`, and waits — for at most ten seconds, so it can never hang the
/// suite — until `<name>-go` exists; then it writes `then` (when given) and exits 0. Its output is
/// written by path each time, as a separate open, the way ffmpeg's file protocol opens it.
private func racingFFmpeg(_ name: String, in folder: URL, first: String, then: String?) throws -> URL {
    let script = folder.appendingPathComponent("\(name)-ffmpeg.sh")
    let finish = then.map { "printf '%s' '\($0)' > \"${out#file:}\"" } ?? ":"
    try """
    #!/bin/sh
    for out; do :; done
    printf '%s' '\(first)' > "${out#file:}"
    : > "\(folder.path)/\(name)-wrote"
    i=0
    while [ ! -e "\(folder.path)/\(name)-go" ] && [ $i -lt 40 ]; do sleep 0.25; i=$((i + 1)); done
    \(finish)
    exit 0
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
}

@Test("Two conversions of one folder never put each other's unfinished output in place (F945)")
func twoConversionsOfOneFolderKeepTheirOwnTemps() async throws {
    // Two app instances whose library lease cannot tell them apart can both convert one interrupted
    // import. Run A has finished writing and is about to exit; run B starts and is part way through.
    // With one temp name for every run, B's start removed A's file as stale and wrote its own under
    // the same name, and A, exiting, renamed B's unfinished output over `recording.wav`.
    let (folder, download, partial) = try makeInterruptedFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    defer {
        // Whatever happens, neither stand-in waits out its ten seconds.
        for name in ["a", "b"] { try? Data().write(to: folder.appendingPathComponent("\(name)-go")) }
    }
    let ffmpegA = try racingFFmpeg("a", in: folder, first: "converted by run A", then: nil)
    let ffmpegB = try racingFFmpeg("b", in: folder, first: "part of run B", then: "converted by run B")

    let runA = Task { try await InterruptedLinkImportExtraction.finish(download: download, ffmpeg: ffmpegA) }
    try #require(await eventually { FileManager.default.fileExists(atPath: folder.appendingPathComponent("a-wrote").path) },
                 "run A's stand-in never wrote its output")
    let runB = Task { try await InterruptedLinkImportExtraction.finish(download: download, ffmpeg: ffmpegB) }
    try #require(await eventually { FileManager.default.fileExists(atPath: folder.appendingPathComponent("b-wrote").path) },
                 "run B's stand-in never started")

    try Data().write(to: folder.appendingPathComponent("a-go"))
    let finishedA = try await runA.value
    let inPlace = try String(contentsOf: finishedA, encoding: .utf8)
    #expect(inPlace == "converted by run A", "run A put another run's output in place")

    try Data().write(to: folder.appendingPathComponent("b-go"))
    let finishedB = try await runB.value
    #expect(finishedB.standardizedFileURL == partial.standardizedFileURL)
    #expect(try String(contentsOf: partial, encoding: .utf8) == "converted by run B")
    #expect(try String(contentsOf: download, encoding: .utf8) == "the complete download")
    #expect(temporaryFiles(in: folder).isEmpty, "a temp file was left: \(temporaryFiles(in: folder))")
}

@Test("A conversion removes the temp files no running conversion holds, and keeps one that is held (F945)")
func aConversionSweepsOnlyAbandonedTemps() async throws {
    let (folder, download, _) = try makeInterruptedFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    // What a quit, crash or kill leaves: the single name earlier builds used, and a run's own name.
    let abandoned = ["recording.extracting.wav", "recording.extracting.\(UUID().uuidString).wav"]
    for name in abandoned {
        try Data("abandoned".utf8).write(to: folder.appendingPathComponent(name))
    }
    // A conversion still running, in this process or another, holds an exclusive lock on its file.
    let running = folder.appendingPathComponent("recording.extracting.\(UUID().uuidString).wav")
    let held = open(running.path, O_RDWR | O_CREAT | O_EXCL | O_EXLOCK | O_NONBLOCK | O_CLOEXEC, 0o644)
    try #require(held >= 0, "could not create the held temp (errno \(errno))")
    defer { close(held) }
    let contents: [UInt8] = Array("a running conversion's".utf8)
    try #require(write(held, contents, contents.count) == contents.count)
    let ffmpeg = try fakeFFmpeg(in: folder, writing: "converted audio", exiting: 0)

    let result = try await InterruptedLinkImportExtraction.finish(download: download, ffmpeg: ffmpeg)

    #expect(try String(contentsOf: result, encoding: .utf8) == "converted audio")
    #expect(temporaryFiles(in: folder) == [running.lastPathComponent],
            "left \(temporaryFiles(in: folder)), expected only the held one")
    #expect(try String(contentsOf: running, encoding: .utf8) == "a running conversion's", "the held temp was changed")
}
