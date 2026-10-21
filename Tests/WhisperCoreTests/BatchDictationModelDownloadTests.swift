import Foundation
import Testing
@testable import WhisperCore

// F860 — on a Mac without the warm helper (Intel), Quick Dictation runs the batch engine:
// openai-whisper's CLI, whose first run downloads the turbo checkpoint (about 1.6 GB) inside the
// first dictation. That download was silent under "Transcribing…" and unbounded (its `urlopen` has
// no timeout). The CLI's download bar is now reported to the same observers the warm engine uses
// (F823, F859), and a bar that stops moving ends the run. This Mac is Apple silicon: the Intel path
// is the batch engine, driven here through a stub `whisper` executable that prints the bars the
// pinned openai-whisper 20250625 prints (`tqdm(unit="iB", unit_scale=True, unit_divisor=1024)`
// `whisper/__init__.py:74-80`).

private final class Recorded<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []
    func append(_ value: Value) { lock.withLock { values.append(value) } }
    var all: [Value] { lock.withLock { values } }
}

/// A `whisper` stand-in: `body` runs with `$out` (the `--output_dir`) and `$name` (the clip's
/// basename without extension) set, so it can write the JSON the client reads.
private func stubWhisper(_ body: String, in directory: URL) throws -> URL {
    let script = directory.appendingPathComponent("whisper")
    try """
    #!/bin/sh
    input="$1"; shift
    out=""
    while [ $# -gt 0 ]; do
      if [ "$1" = "--output_dir" ]; then out="$2"; shift; fi
      shift
    done
    name=$(basename "$input"); name="${name%.*}"
    \(body)
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
}

private let transcriptJSON = #"{"text": " Hello from the batch engine.", "language": "en", "segments": [{"start": 0.0, "end": 1.0, "text": " Hello from the batch engine.", "no_speech_prob": 0.01}]}"#

private func temporaryDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func batchEngine(whisper: URL, in directory: URL) throws -> (BatchWhisperDictationEngine, URL) {
    let clip = directory.appendingPathComponent("clip.wav")
    try shortReadableWAV().write(to: clip)
    let engine = BatchWhisperDictationEngine(
        client: LocalWhisperClient(
            executableURL: whisper, modelDirectory: directory.appendingPathComponent("models"),
            scratchDirectory: directory.appendingPathComponent("scratch") // F937: not the real $TMPDIR
        ),
        model: .turbo
    )
    return (engine, clip)
}

/// Polls `condition` under a 30 s cap and requires it (F645).
private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    let deadline = SuspendingClock.now + .seconds(30)
    while !condition(), SuspendingClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    try #require(condition(), "timed out waiting for \(what)")
}

@Test("The batch engine reports openai-whisper's checkpoint download, with its percentage, and its end (F860)")
func batchEngineReportsTheCheckpointDownload() async throws {
    let tmp = try temporaryDirectory("F860-download")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let go = tmp.appendingPathComponent("go")
    defer { try? Data().write(to: go) }
    // The download bar, then a wait the test ends once it has seen the download, then the rest of
    // the bar and the transcription bar — separate writes, so the parser sees them as they come.
    let whisper = try stubWhisper("""
    printf '  0%%|          | 0.00/1.51G [00:00<?, ?iB/s]\\r' >&2
    printf ' 42%%|####2     | 650M/1.51G [00:05<00:07, 120MiB/s]\\r' >&2
    i=0; while [ -d "\(tmp.path)" ] && [ ! -e "\(go.path)" ] && [ $i -lt 1200 ]; do i=$((i+1)); sleep 0.05; done
    printf '100%%|##########| 1.51G/1.51G [00:12<00:00, 125MiB/s]\\n' >&2
    printf ' 50%%|#####     | 100/200 [00:01<00:01, 100.00frames/s]\\r' >&2
    printf '%s' '\(transcriptJSON)' > "$out/$name.json"
    """, in: tmp)
    let (engine, clip) = try batchEngine(whisper: whisper, in: tmp)
    let states = Recorded<Bool>()
    let figures = Recorded<Int>()
    engine.observeModelDownload { states.append($0) }
    engine.observeModelDownloadProgress { figures.append($0.percent) }

    let run = Task { try await engine.transcribe(wavAt: clip, language: .automatic, initialPrompt: nil) }
    try await waitUntil("the download to be reported") { figures.all.contains(42) }
    #expect(states.all == [true], "the download is showing while the bar is")
    try Data().write(to: go)
    let result = try await run.value

    #expect(result.text == "Hello from the batch engine.")
    #expect(states.all == [true, false])
    #expect(figures.all.last == 42 || figures.all.last == 100, "\(figures.all)")
}

@Test("A checkpoint download whose bar stops moving is stopped, and the error says why (F860)")
func batchEngineStopsAStalledCheckpointDownload() async throws {
    let tmp = try temporaryDirectory("F860-stall")
    defer { try? FileManager.default.removeItem(at: tmp) }
    // One bar, then nothing: openai-whisper's `urlopen` has no timeout, so only the engine ends it.
    let whisper = try stubWhisper("""
    printf '  3%%|3         | 48.0M/1.51G [00:01<00:30, 48.0MiB/s]\\r' >&2
    i=0; while [ -d "\(tmp.path)" ] && [ $i -lt 1200 ]; do i=$((i+1)); sleep 0.05; done
    """, in: tmp)
    let (engine, clip) = try batchEngine(whisper: whisper, in: tmp)
    engine.downloadStallTimeout = 1
    let states = Recorded<Bool>()
    engine.observeModelDownload { states.append($0) }

    var caught: Error?
    do {
        _ = try await engine.transcribe(wavAt: clip, language: .automatic, initialPrompt: nil)
    } catch {
        caught = error
    }
    let stall = try #require(caught as? DictationModelDownloadError, "\(String(describing: caught))")
    #expect(stall.message.contains("no progress for 1 seconds"), "\(stall.message)")
    #expect(states.all == [true, false], "a stopped download must not stay showing")
}

@Test("A bar at 100 % ends the download and its stall window: openai-whisper's hash and model load after it are not a stall (F860)")
func batchEngineDoesNotStallAfterTheDownloadFinishes() async throws {
    // Review R6 (round 2): after the 100 % bar openai-whisper re-reads and hashes the whole file,
    // then loads it and computes the first window, all before its first `frames` bar — on a slow
    // Intel Mac that can outlast the stall window, which used to stop a dictation whose download had
    // finished. The test holds that silence for three windows before letting the stub go on.
    let tmp = try temporaryDirectory("F860-finished")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let go = tmp.appendingPathComponent("go")
    defer { try? Data().write(to: go) }
    let whisper = try stubWhisper("""
    printf ' 42%%|####2     | 650M/1.51G [00:05<00:07, 120MiB/s]\\r' >&2
    printf '100%%|##########| 1.51G/1.51G [00:12<00:00, 125MiB/s]\\n' >&2
    i=0; while [ -d "\(tmp.path)" ] && [ ! -e "\(go.path)" ] && [ $i -lt 1200 ]; do i=$((i+1)); sleep 0.05; done
    printf ' 50%%|#####     | 100/200 [00:01<00:01, 100.00frames/s]\\r' >&2
    printf '%s' '\(transcriptJSON)' > "$out/$name.json"
    """, in: tmp)
    let (engine, clip) = try batchEngine(whisper: whisper, in: tmp)
    engine.downloadStallTimeout = 1
    let states = Recorded<Bool>()
    let figures = Recorded<Int>()
    let finished = Recorded<Bool>()
    engine.observeModelDownload { states.append($0) }
    engine.observeModelDownloadProgress { figures.append($0.percent) }

    let run = Task {
        defer { finished.append(true) }
        return try await engine.transcribe(wavAt: clip, language: .automatic, initialPrompt: nil)
    }
    try await waitUntil("the finished download to be reported") { figures.all.contains(100) }
    // The subject is that nothing ends the run while openai-whisper is silent after 100 %: three stall
    // windows of it, or the run ending first, whichever comes sooner.
    let quietUntil = SuspendingClock.now + .seconds(3)
    while finished.all.isEmpty, SuspendingClock.now < quietUntil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(finished.all.isEmpty, "the run was stopped after its download had finished")
    #expect(states.all == [true, false], "a finished download is no longer showing")

    try Data().write(to: go)
    let outcome = await run.result
    let result = try outcome.get()
    #expect(result.text == "Hello from the batch engine.")
    #expect(states.all == [true, false])
}

@Test("A checkpoint already on disk: nothing is reported, and nothing is stopped (F860 control)")
func batchEngineWithACachedCheckpointReportsNothing() async throws {
    let tmp = try temporaryDirectory("F860-cached")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let whisper = try stubWhisper("""
    printf ' 50%%|#####     | 100/200 [00:01<00:01, 100.00frames/s]\\r' >&2
    printf '%s' '\(transcriptJSON)' > "$out/$name.json"
    """, in: tmp)
    let (engine, clip) = try batchEngine(whisper: whisper, in: tmp)
    engine.downloadStallTimeout = 1
    let states = Recorded<Bool>()
    let figures = Recorded<Int>()
    engine.observeModelDownload { states.append($0) }
    engine.observeModelDownloadProgress { figures.append($0.percent) }

    let result = try await engine.transcribe(wavAt: clip, language: .automatic, initialPrompt: nil)

    #expect(result.text == "Hello from the batch engine.")
    #expect(states.all.isEmpty)
    #expect(figures.all.isEmpty)
}
