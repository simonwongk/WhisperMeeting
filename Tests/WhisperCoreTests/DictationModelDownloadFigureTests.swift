import Foundation
import Testing
@testable import WhisperCore

// F859 — the helper's `{"downloading": true}` reports carried no byte counts, so the app could say
// that the 1.6 GB model was downloading (F823) but not how far it had got. A current helper adds
// `downloadedBytes`/`totalBytes`; the engine hands them to a progress observer. Both fields are
// optional on the wire: a helper from before F859 sends neither and must read exactly as before.
// Stub helpers are `/bin/sh` scripts, as in F522's and F823's tests.

private final class Figures: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DictationModelDownloadProgress] = []
    func append(_ value: DictationModelDownloadProgress) { lock.withLock { values.append(value) } }
    var all: [DictationModelDownloadProgress] { lock.withLock { values } }
}

private final class States: @unchecked Sendable {
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

@Test("The helper's byte counts reach the progress observer, after the download's start (F859)")
func warmEngineHandsTheHelpersByteCountsToTheProgressObserver() async throws {
    let tmp = try temporaryDirectory("F859-figures")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let engine = try stubEngine("""
    printf '{"downloading":true}\\n'
    printf '{"downloading":true,"downloadedBytes":0,"totalBytes":1613977880}\\n'
    printf '{"downloading":true,"downloadedBytes":677870710,"totalBytes":1613977880}\\n'
    printf '{"downloading":false}\\n'
    printf '{"ready":true}\\n'
    IFS= read -r request
    """, in: tmp)
    defer { engine.shutdown() }
    let figures = Figures()
    let states = States()
    engine.observeModelDownload { states.append($0) }
    engine.observeModelDownloadProgress { figures.append($0) }

    try await engine.warmUp()

    let expected: [DictationModelDownloadProgress] = [
        try #require(DictationModelDownloadProgress(downloadedBytes: 0, totalBytes: 1_613_977_880)),
        try #require(DictationModelDownloadProgress(downloadedBytes: 677_870_710, totalBytes: 1_613_977_880)),
    ]
    #expect(figures.all == expected)
    #expect(figures.all.map(\.percent) == [0, 42])
    #expect(figures.all.last?.totalBytes == 1_613_977_880)
    #expect(states.all == [true, false], "the figures must not change what F823's observer hears")
}

@Test("A helper from before F859 sends no counts: the download is still reported, with no figure (F859)")
func warmEngineReadsAnOlderHelpersReportsAsBefore() async throws {
    let tmp = try temporaryDirectory("F859-older")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let engine = try stubEngine("""
    printf '{"downloading":true}\\n'
    printf '{"downloading":true}\\n'
    printf '{"downloading":false}\\n'
    printf '{"ready":true}\\n'
    IFS= read -r request
    """, in: tmp)
    defer { engine.shutdown() }
    let figures = Figures()
    let states = States()
    engine.observeModelDownload { states.append($0) }
    engine.observeModelDownloadProgress { figures.append($0) }

    try await engine.warmUp()

    #expect(states.all == [true, false])
    #expect(figures.all.isEmpty)
}

@Test("Counts that are not a measurement are no figure, and the line still reports the download (F859)")
func warmEngineIgnoresCountsThatAreNotAMeasurement() async throws {
    let tmp = try temporaryDirectory("F859-garbage")
    defer { try? FileManager.default.removeItem(at: tmp) }
    // A zero total, a negative count, a fraction, a number past Int64, a string, one field alone.
    let engine = try stubEngine("""
    printf '{"downloading":true,"downloadedBytes":5,"totalBytes":0}\\n'
    printf '{"downloading":true,"downloadedBytes":-5,"totalBytes":10}\\n'
    printf '{"downloading":true,"downloadedBytes":2.5,"totalBytes":10}\\n'
    printf '{"downloading":true,"downloadedBytes":1,"totalBytes":1e30}\\n'
    printf '{"downloading":true,"downloadedBytes":"1","totalBytes":10}\\n'
    printf '{"downloading":true,"totalBytes":10}\\n'
    printf '{"downloading":false}\\n'
    printf '{"ready":true}\\n'
    IFS= read -r request
    """, in: tmp)
    defer { engine.shutdown() }
    let figures = Figures()
    let states = States()
    engine.observeModelDownload { states.append($0) }
    engine.observeModelDownloadProgress { figures.append($0) }

    try await engine.warmUp()

    #expect(figures.all.isEmpty)
    #expect(states.all == [true, false])
}

@Test("A figure reads as a whole percent rounded down, so 100 means finished (F859)")
func downloadProgressReadsAsAWholePercent() throws {
    #expect(try #require(DictationModelDownloadProgress(downloadedBytes: 999, totalBytes: 1_000)).percent == 99)
    #expect(try #require(DictationModelDownloadProgress(downloadedBytes: 1_000, totalBytes: 1_000)).percent == 100)
    #expect(try #require(DictationModelDownloadProgress(downloadedBytes: 2_000, totalBytes: 1_000)).percent == 100)
    #expect(DictationModelDownloadProgress(fractionCompleted: .nan).percent == 0)
    #expect(DictationModelDownloadProgress(fractionCompleted: 1e30).percent == 100)
    #expect(DictationModelDownloadProgress(fractionCompleted: -3).percent == 0)
    #expect(DictationModelDownloadProgress(downloadedBytes: 1, totalBytes: 0) == nil)
}

/// Records the progress observer it was handed, and can report through it.
private final class FigureEngine: DictationEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var observer: DictationModelDownloadProgressObserver?
    var hasObserver: Bool { lock.withLock { observer != nil } }
    func observeModelDownloadProgress(_ observer: DictationModelDownloadProgressObserver?) {
        lock.withLock { self.observer = observer }
    }
    func report(_ value: DictationModelDownloadProgress) { lock.withLock { observer }?(value) }
    func warmUp() async throws {}
    func transcribe(wavAt url: URL, language: WhisperLanguage, initialPrompt: String?) async throws -> DictationResult {
        DictationResult(text: "", languageCode: nil)
    }
    func shutdown() {}
}

@Test("The selectable and fallback engines pass the progress observer on, including to a model chosen later (F859)")
func wrappingEnginesForwardTheProgressObserver() async throws {
    let first = FigureEngine()
    let selectable = SelectableDictationEngine(engine: first)
    let figures = Figures()
    selectable.observeModelDownloadProgress { figures.append($0) }
    #expect(first.hasObserver)

    let primary = FigureEngine()
    let fallback = FigureEngine()
    await selectable.replace(with: FallbackDictationEngine(primary: primary, fallback: fallback))
    #expect(primary.hasObserver)
    #expect(fallback.hasObserver, "the batch engine reports its own download (F860)")

    fallback.report(DictationModelDownloadProgress(fractionCompleted: 0.25))
    #expect(figures.all.map(\.percent) == [25])
}
