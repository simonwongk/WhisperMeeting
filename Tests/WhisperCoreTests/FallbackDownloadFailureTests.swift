import Foundation
import Testing
@testable import WhisperCore

// F827 — `FallbackDictationEngine.warmUp` caught EVERY error from the warm engine and switched to the
// batch engine, which downloads a second ~1.5 GB model on the same link. Since F522 the warm engine
// gives up on a stalled first-run download after minutes rather than 30, so that switch came sooner,
// and the "made no progress" message F522 wrote was never seen by anyone. These run the real warm
// engine against stub helpers (`/bin/sh` scripts speaking the helper's wire protocol) behind a real
// `FallbackDictationEngine`, and assert on outcomes only — no duration is asserted.

private final class CountingEngine: DictationEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var warms = 0
    private var transcribes = 0

    var warmCount: Int { lock.withLock { warms } }
    var transcribeCount: Int { lock.withLock { transcribes } }

    func warmUp() async throws { lock.withLock { warms += 1 } }

    func transcribe(
        wavAt url: URL, language: WhisperLanguage, initialPrompt: String?
    ) async throws -> DictationResult {
        lock.withLock { transcribes += 1 }
        return DictationResult(text: "batch engine", languageCode: nil)
    }

    func shutdown() {}
}

/// What an operation ended with, readable from the polling test body.
private final class Outcome<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Value, Error>?

    func set(_ result: Result<Value, Error>) { lock.withLock { stored = result } }
    var value: Result<Value, Error>? { lock.withLock { stored } }
}

/// Runs `operation` unstructured and polls its outcome under a 30 s wall-clock cap, so a hang fails
/// on the wait instead of hanging the suite.
private func finish<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Result<Value, Error> {
    let outcome = Outcome<Value>()
    Task {
        do { outcome.set(.success(try await operation())) } catch { outcome.set(.failure(error)) }
    }
    var ticks = 0
    while outcome.value == nil, ticks < 6_000 {
        try await Task.sleep(nanoseconds: 5_000_000)
        ticks += 1
    }
    return try #require(outcome.value, "the operation never finished")
}

private func makeStubDirectory(_ name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private let wavURL = URL(fileURLWithPath: "/tmp/f827.wav")

@Test("A stalled first-run model download is not fallen back from, and its message reaches the caller (F827)")
func fallbackDoesNotSwallowAStalledModelDownload() async throws {
    let tmp = try makeStubDirectory("FallbackStall")
    defer { try? FileManager.default.removeItem(at: tmp) }
    // One progress report, then silence; the helper cannot exit by itself until the test releases
    // it, so an error can only mean the engine stopped it.
    let release = tmp.appendingPathComponent("release")
    defer { try? Data().write(to: release) }
    let script = tmp.appendingPathComponent("stalled.sh")
    try """
    printf '{"downloading":true}\\n'
    while [ -d "\(tmp.path)" ] && [ ! -e "\(release.path)" ]; do sleep 0.05; done
    """.write(to: script, atomically: true, encoding: .utf8)

    let primary = WarmWhisperDictationEngine(
        python: URL(fileURLWithPath: "/bin/sh"), script: script, modelDirectory: tmp
    )
    defer { primary.shutdown() }
    primary.warmUpTimeout = 600
    primary.downloadStallTimeout = 1
    let batch = CountingEngine()
    let engine = FallbackDictationEngine(primary: primary, fallback: batch)

    let warm = try await finish { try await engine.warmUp() }
    guard case let .failure(error) = warm else {
        Issue.record("warm-up succeeded: the engine fell back instead of reporting the stalled download")
        return
    }
    let download = error as? DictationModelDownloadError
    #expect(download != nil, "got \(error) rather than the download error")
    #expect(download?.message.contains("no progress") == true, "got: \(error)")
    #expect(ErrorPresentation.sentence(for: error, fallback: "") .contains("no progress"),
            "the sentence the pill shows must be the helper's, not the generic fallback")
    #expect(batch.warmCount == 0, "the batch engine must not be warmed — it would download a second model")

    // And a transcribe that arrives next is refused the same way rather than served by the batch engine.
    let transcribed = try await finish {
        try await engine.transcribe(wavAt: wavURL, language: .automatic, initialPrompt: nil)
    }
    if case .success = transcribed { Issue.record("transcribe was served by the batch engine") }
    #expect(batch.transcribeCount == 0)
}

@Test("A download the helper reports as failed is not fallen back from either (F827)")
func fallbackDoesNotSwallowAReportedDownloadFailure() async throws {
    let tmp = try makeStubDirectory("FallbackReported")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let script = tmp.appendingPathComponent("failed.sh")
    try """
    printf '{"downloading":true}\\n'
    printf '{"downloading":false}\\n'
    printf '{"error":"model download failed: the model download stopped at 5 of 10 bytes","downloadFailed":true}\\n'
    """.write(to: script, atomically: true, encoding: .utf8)

    let primary = WarmWhisperDictationEngine(
        python: URL(fileURLWithPath: "/bin/sh"), script: script, modelDirectory: tmp
    )
    defer { primary.shutdown() }
    let batch = CountingEngine()
    let engine = FallbackDictationEngine(primary: primary, fallback: batch)

    let warm = try await finish { try await engine.warmUp() }
    guard case let .failure(error) = warm else {
        Issue.record("warm-up succeeded: the engine fell back instead of reporting the failed download")
        return
    }
    #expect((error as? DictationModelDownloadError)?.message.contains("stopped at 5 of 10 bytes") == true,
            "got: \(error)")
    #expect(batch.warmCount == 0)
}

@Test("Failures the batch engine genuinely avoids still fall back (F827)")
func fallbackStillHandlesAHelperThatCannotRunHere() async throws {
    let tmp = try makeStubDirectory("FallbackCannotRun")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let script = tmp.appendingPathComponent("no-mlx.sh")
    try """
    printf '{"error":"warm-up failed: No module named mlx"}\\n'
    """.write(to: script, atomically: true, encoding: .utf8)

    let primary = WarmWhisperDictationEngine(
        python: URL(fileURLWithPath: "/bin/sh"), script: script, modelDirectory: tmp
    )
    defer { primary.shutdown() }
    let batch = CountingEngine()
    let engine = FallbackDictationEngine(primary: primary, fallback: batch)

    let warm = try await finish { try await engine.warmUp() }
    if case let .failure(error) = warm { Issue.record("an MLX import failure should fall back, got \(error)") }
    let transcribed = try await finish {
        try await engine.transcribe(wavAt: wavURL, language: .automatic, initialPrompt: nil)
    }
    if case let .success(result) = transcribed { #expect(result.text == "batch engine") }
    #expect(batch.warmCount == 1)
}

@Test("After a download failure the next warm-up retries the warm engine instead of staying on the batch engine (F827)")
func nextWarmUpRetriesTheWarmEngineAfterADownloadFailure() async throws {
    let tmp = try makeStubDirectory("FallbackRetry")
    defer { try? FileManager.default.removeItem(at: tmp) }
    // The first launch fails its download and leaves a marker; the second finds the marker (the
    // partial file the real helper keeps) and finishes, then answers one request.
    let marker = tmp.appendingPathComponent("partial")
    let script = tmp.appendingPathComponent("flaky.sh")
    try """
    if [ ! -e "\(marker.path)" ]; then
      : > "\(marker.path)"
      printf '{"error":"model download failed: link dropped","downloadFailed":true}\\n'
      exit 1
    fi
    printf '{"ready":true}\\n'
    IFS= read -r request
    printf '{"text":"warm engine","language":"en"}\\n'
    """.write(to: script, atomically: true, encoding: .utf8)

    let primary = WarmWhisperDictationEngine(
        python: URL(fileURLWithPath: "/bin/sh"), script: script, modelDirectory: tmp
    )
    defer { primary.shutdown() }
    let batch = CountingEngine()
    let engine = FallbackDictationEngine(primary: primary, fallback: batch)

    let first = try await finish { try await engine.warmUp() }
    if case .success = first { Issue.record("the first warm-up should have reported the failed download") }

    let second = try await finish { try await engine.warmUp() }
    if case let .failure(error) = second { Issue.record("the retry should have warmed the warm engine, got \(error)") }
    let transcribed = try await finish {
        try await engine.transcribe(wavAt: wavURL, language: .automatic, initialPrompt: nil)
    }
    if case let .success(result) = transcribed { #expect(result.text == "warm engine") }
    #expect(batch.warmCount == 0)
    #expect(batch.transcribeCount == 0)
}
