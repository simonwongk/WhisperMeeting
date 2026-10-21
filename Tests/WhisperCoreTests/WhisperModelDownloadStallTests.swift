import Foundation
import Testing
@testable import WhisperCore

// F901 — a meeting's first transcription with a model not yet on disk downloads it inside the
// `whisper` run, and openai-whisper's `_download` opens the URL with no timeout
// (`urllib.request.urlopen(url)`, `whisper/__init__.py` on main, checked 2026-10-16). A dead connection
// waited until Cancel. With `downloadStallTimeout` the client stops the run once the download bar has
// not moved for that long, and throws a reason a meeting can show and retry from. The stub prints
// openai-whisper's own download bar (`unit="iB"`), which `WhisperProgressParser` reads as
// `.downloadingModel`.

private func scratch(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A stub `whisper` running `body` after reading where to write; `$out/$name.json` is the transcript.
private func stubWhisper(in directory: URL, _ body: String) throws -> URL {
    let url = directory.appendingPathComponent("whisper")
    try """
    #!/bin/zsh
    input="$1"; shift
    out=""
    while (( $# > 0 )); do
      [[ "$1" == "--output_dir" ]] && { out="$2"; shift; }
      shift
    done
    name="${input:t:r}"
    \(body)
    """.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private let transcript = #"{"text":" Hello.","language":"en","segments":[{"start":0.0,"end":1.0,"text":" Hello."}]}"#

private func client(_ whisper: URL, in directory: URL, stall: TimeInterval?) -> LocalWhisperClient {
    LocalWhisperClient(
        executableURL: whisper, modelDirectory: directory.appendingPathComponent("models"),
        scratchDirectory: directory.appendingPathComponent("runs"), // F937: not the real $TMPDIR
        downloadStallTimeout: stall
    )
}

@Test("A meeting run whose model download stops moving is stopped, and says why (F901)")
func aStalledModelDownloadStopsTheRun() async throws {
    let dir = try scratch("F901-stall"); defer { try? FileManager.default.removeItem(at: dir) }
    let pidFile = dir.appendingPathComponent("whisper.pid")
    let whisper = try stubWhisper(in: dir, """
    print -r -- $$ > '\(pidFile.path)'
    printf ' 42%%|####2     | 650M/1.51G [00:05<00:07, 120MiB/s]\\r' >&2
    exec sleep 120
    """)
    let audio = dir.appendingPathComponent("meeting.wav")
    try shortReadableWAV().write(to: audio)
    let started = ContinuousClock.now

    await #expect(throws: LocalWhisperError.modelDownloadStalled(seconds: 1)) {
        try await client(whisper, in: dir, stall: 1).transcribe(recordingAt: audio)
    }

    #expect(ContinuousClock.now - started < .seconds(60), "the run waited for the stub's own two minutes")
    // The stalled process is stopped with the run, not left downloading.
    let pid = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    let deadline = SuspendingClock.now + .seconds(30)
    while kill(pid, 0) == 0, SuspendingClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(kill(pid, 0) != 0, "the stalled whisper is still running")
    #expect(LocalWhisperError.modelDownloadStalled(seconds: 180).errorDescription
            == "The Whisper model download made no progress for 180 seconds and was stopped. Check your connection, then transcribe again.")
}

@Test("A download that reaches 100 % ends the window: hashing and loading the model after it are not a stall (F901)")
func aFinishedDownloadIsNotAStall() async throws {
    let dir = try scratch("F901-finished"); defer { try? FileManager.default.removeItem(at: dir) }
    let whisper = try stubWhisper(in: dir, """
    printf ' 42%%|####2     | 650M/1.51G [00:05<00:07, 120MiB/s]\\r' >&2
    printf '100%%|##########| 1.51G/1.51G [00:12<00:00, 120MiB/s]\\n' >&2
    sleep 2.5
    printf '%s' '\(transcript)' > "$out/$name.json"
    """)
    let audio = dir.appendingPathComponent("meeting.wav")
    try shortReadableWAV().write(to: audio)

    let result = try await client(whisper, in: dir, stall: 1).transcribe(recordingAt: audio)

    #expect(result.text == "Hello.")
}

// The review of F901: on a slow connection (under ~160 KB/s for large-v3, about 1 % per 180 s) the
// whole percent stands still for longer than the window, and movement rests on the rest of tqdm's line —
// the estimate of the time left, which `WhisperProgressParser` reads and reports when it changes. Here
// the percent and the byte count never change, and only the estimate does, every half second.
@Test("A slow download whose percent stands still but whose time left keeps changing is not stopped (F901)")
func aSlowDownloadWithAMovingEstimateIsNotStopped() async throws {
    let dir = try scratch("F901-slow"); defer { try? FileManager.default.removeItem(at: dir) }
    let whisper = try stubWhisper(in: dir, """
    for i in {0..24}; do printf ' 42%%|####2     | 650M/1.51G [00:%02d<%02d:00, 160kiB/s]\\r' $((i / 5)) $((89 - i / 5)) >&2; sleep 0.1; done
    printf '100%%|##########| 1.51G/1.51G [00:12<00:00, 120MiB/s]\\n' >&2
    printf '%s' '\(transcript)' > "$out/$name.json"
    """)
    let audio = dir.appendingPathComponent("meeting.wav")
    try shortReadableWAV().write(to: audio)

    // 2.5 s at 42 % against a 1 s window: stopped unless a changed estimate counts as movement.
    let result = try await client(whisper, in: dir, stall: 1).transcribe(recordingAt: audio)

    #expect(result.text == "Hello.")
}

@Test("A download whose bar keeps moving runs past the window (F901 control)")
func aMovingDownloadIsNotStopped() async throws {
    let dir = try scratch("F901-moving"); defer { try? FileManager.default.removeItem(at: dir) }
    let whisper = try stubWhisper(in: dir, """
    for i in {10..34}; do printf ' %d%%|##        | %dM/1.51G [00:01<00:07, 120MiB/s]\\r' $i $((i * 15)) >&2; sleep 0.1; done
    printf '100%%|##########| 1.51G/1.51G [00:12<00:00, 120MiB/s]\\n' >&2
    printf '%s' '\(transcript)' > "$out/$name.json"
    """)
    let audio = dir.appendingPathComponent("meeting.wav")
    try shortReadableWAV().write(to: audio)

    // 25 updates a tenth of a second apart: 2.5 s of download against a 1 s window.
    let result = try await client(whisper, in: dir, stall: 1).transcribe(recordingAt: audio)

    #expect(result.text == "Hello.")
}

/// A suspending clock the test moves by hand: time the Mac spends asleep does not move it.
private final class HandClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = SuspendingClock.now
    var now: SuspendingClock.Instant { lock.withLock { instant } }
    func advance(_ by: Duration) { lock.withLock { instant = instant.advanced(by: by) } }
}

/// F1067 — the window used to be timed on `ContinuousClock`, which counts sleep, so a download across a
/// lid close longer than the window was stopped the first time the watch looked after waking. It is
/// timed on `SuspendingClock` now (the type of the clock it takes says so): while the Mac sleeps no
/// progress is expected and none is missed.
@Test("The download stall window does not count time the Mac sleeps (F1067)")
func theStallWindowStandsStillWhileTheMacSleeps() async throws {
    final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var stalled = false
        var value: Bool { lock.withLock { stalled } }
        func set() { lock.withLock { stalled = true } }
    }
    let clock = HandClock()
    let watch = ModelDownloadStallWatch(stallTimeout: 0.1, now: { clock.now })
    watch.observe(LocalTranscriptionProgress(phase: .downloadingModel, fractionCompleted: 0.03))
    let outcome = Outcome()
    let task = Task {
        do { try await watch.waitForStall() } catch LocalWhisperError.modelDownloadStalled { outcome.set() } catch {}
    }
    defer { task.cancel() }
    // Asleep: real time passes, five windows of it, and the suspending clock does not move.
    try await Task.sleep(for: .milliseconds(500))
    #expect(!outcome.value, "time the Mac slept was taken for a download that stopped moving")
    // Awake again, with no progress for longer than the window: now it is a stall.
    clock.advance(.milliseconds(200))
    try await pollUntil("an awake window with no progress to stop the download") { outcome.value }
}
