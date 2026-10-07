import Foundation
import Testing
@testable import WhisperCore

// F823 — the helper's `{"downloading": …}` reports reached `WarmWhisperDictationEngine.readLine`
// (F522) and stopped there, so the app said nothing while 1.6 GB downloaded. The engine now tells an
// observer when a download starts and when it ends, however the wait ends. Stub helpers are `/bin/sh`
// scripts, as in F522's tests; every wait is bounded and `#require`d (F645).

private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    func append(_ value: Bool) { lock.withLock { values.append(value) } }
    var all: [Bool] { lock.withLock { values } }
}

private func stubEngine(_ body: String, in directory: URL) throws -> WarmWhisperDictationEngine {
    let script = directory.appendingPathComponent("helper.sh")
    try body.write(to: script, atomically: true, encoding: .utf8)
    return WarmWhisperDictationEngine(python: URL(fileURLWithPath: "/bin/sh"), script: script, modelDirectory: directory)
}

private func temporaryDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test("The warm engine tells its observer once when the model download starts and once when it ends (F823)")
func warmEngineReportsADownloadsStartAndEnd() async throws {
    let tmp = try temporaryDirectory("F823-download")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let engine = try stubEngine("""
    printf '{"downloading":true}\\n'
    printf '{"downloading":true}\\n'
    printf '{"downloading":true}\\n'
    printf '{"downloading":false}\\n'
    printf '{"ready":true}\\n'
    IFS= read -r request
    """, in: tmp)
    defer { engine.shutdown() }
    let reports = Reports()
    engine.observeModelDownload { reports.append($0) }

    try await engine.warmUp()

    // Reported on the engine's queue before `warmUp` returns, so nothing is still in flight.
    #expect(reports.all == [true, false])
}

@Test("A download that stalls still ends on the observer, so the app never shows one forever (F823)")
func warmEngineEndsAStalledDownloadOnTheObserver() async throws {
    let tmp = try temporaryDirectory("F823-stall")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let release = tmp.appendingPathComponent("release")
    defer { try? Data().write(to: release) }
    // One report, then silence; the helper cannot exit by itself, so only the engine ends it.
    let engine = try stubEngine("""
    printf '{"downloading":true}\\n'
    while [ -d "\(tmp.path)" ] && [ ! -e "\(release.path)" ]; do sleep 0.05; done
    """, in: tmp)
    defer { engine.shutdown() }
    engine.warmUpTimeout = 600
    engine.downloadStallTimeout = 1
    let reports = Reports()
    engine.observeModelDownload { reports.append($0) }

    await #expect(throws: DictationModelDownloadError.self) { try await engine.warmUp() }
    #expect(reports.all == [true, false])
}

@Test("A helper whose model is already cached tells the observer nothing (F823 control)")
func warmEngineWithACachedModelReportsNothing() async throws {
    let tmp = try temporaryDirectory("F823-cached")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let engine = try stubEngine("""
    printf '{"ready":true}\\n'
    IFS= read -r request
    """, in: tmp)
    defer { engine.shutdown() }
    let reports = Reports()
    engine.observeModelDownload { reports.append($0) }

    try await engine.warmUp()

    #expect(reports.all.isEmpty)
}

/// Records the observer it was handed, and can report through it.
private final class ObservedEngine: DictationEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var observer: DictationModelDownloadObserver?
    var hasObserver: Bool { lock.withLock { observer != nil } }
    func observeModelDownload(_ observer: DictationModelDownloadObserver?) { lock.withLock { self.observer = observer } }
    func report(_ value: Bool) { lock.withLock { observer }?(value) }
    func warmUp() async throws {}
    func transcribe(wavAt url: URL, language: WhisperLanguage, initialPrompt: String?) async throws -> DictationResult {
        DictationResult(text: "", languageCode: nil)
    }
    func shutdown() {}
}

@Test("The selectable and fallback engines pass the observer on, including to a model chosen later (F823)")
func wrappingEnginesForwardTheDownloadObserver() async throws {
    let first = ObservedEngine()
    let selectable = SelectableDictationEngine(engine: first)
    let reports = Reports()
    selectable.observeModelDownload { reports.append($0) }
    #expect(first.hasObserver)

    let primary = ObservedEngine()
    let fallback = ObservedEngine()
    await selectable.replace(with: FallbackDictationEngine(primary: primary, fallback: fallback))
    #expect(primary.hasObserver)
    #expect(fallback.hasObserver)

    primary.report(true)
    primary.report(false)
    #expect(reports.all == [true, false])
}

@Test("The batch engine's turbo checkpoint is the file openai-whisper keeps in the model directory (F823)")
func turboCheckpointIsLookedForWhereWhisperKeepsIt() throws {
    let support = try temporaryDirectory("F823-checkpoint")
    defer { try? FileManager.default.removeItem(at: support) }
    #expect(LocalWhisperRuntime.checkpointFileName(for: .turbo) == "large-v3-turbo.pt")
    #expect(!LocalWhisperRuntime.checkpointCached(.turbo, applicationSupport: support))

    let models = LocalWhisperRuntime.modelDirectory(applicationSupport: support)
    try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
    try Data([0]).write(to: models.appendingPathComponent("large-v3-turbo.pt"))

    #expect(LocalWhisperRuntime.checkpointCached(.turbo, applicationSupport: support))
    #expect(!LocalWhisperRuntime.checkpointCached(.large, applicationSupport: support))
}
