import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

// F859 — the Dictation tab, the model row and the menu bar said "downloading" with no figure,
// because the helper's reports carried no byte counts. A stub helper's counts now reach that text
// through the real warm engine and the real controller. The rig is shared with
// `BatchDictationDownloadSurfaceTests` (F860).

@MainActor
final class DownloadSurfacePhaseLog: DictationOverlayPresenting {
    private(set) var phases: [DictationOverlay.Phase] = []
    var onCopy: (() -> Void)?
    func show(_ phase: DictationOverlay.Phase) { phases.append(phase) }
    func update(level: Float) {}
    func hide() {}
}

/// A speech detector that cannot tell, so the clip is transcribed as it would be without one (F846).
struct UndecidedSpeechDetector: DictationSpeechDetecting {
    func peakSpeechProbability(ofClipAt url: URL) async -> Float? { nil }
}

/// A real controller with fakes for everything but its engine, which the test supplies.
@MainActor
struct DownloadSurfaceRig {
    let controller: DictationController
    let monitor = FakeHotkeyMonitor()
    let overlay = DownloadSurfacePhaseLog()
    let directory: URL
    let cleanUp: () -> Void

    init(engine: DictationEngine) throws {
        let suite = testSuiteName()
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationModelDownloadFigure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        defaults.set(true, forKey: "dictationEnabled")
        defaults.set(false, forKey: "dictationAutoPaste")
        let clip = directory.appendingPathComponent("clip.wav")
        // Half a second of a tone in a readable WAV, as the recorder writes one: loud enough for the
        // speech floor (F599). A few bytes of text named `.wav` is decoded by ffmpeg first since
        // F903, so where ffmpeg is installed the batch engine's test would test ffmpeg's error.
        let tone = (0..<8_000).map { Float(0.3 * sin(2 * Double.pi * 440 * Double($0) / 16_000)) }
        try WAVWriter.wavData(from: tone, sampleRate: 16_000).write(to: clip)
        controller = DictationController(
            defaults: defaults,
            engine: engine,
            recorder: FakeDictationRecorder(outputURL: clip),
            overlay: overlay,
            hotkeyMonitor: monitor,
            logStore: DictationLogStore(directory: directory),
            captureSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            refiner: FakeRefiner(),
            textInjector: isolatedTextInjector(),
            activateOnInit: false
        )
        controller.clipboardNotifier = {}
        controller.announce = { _ in }
        controller.speechDetector = UndecidedSpeechDetector()
        cleanUp = {
            engine.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Polls `condition` under a 30 s cap and requires it (F645).
    func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = SuspendingClock.now + .seconds(30)
        while !condition(), SuspendingClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition(), "timed out waiting for \(what)")
    }
}

@MainActor
@Test("A stub helper's byte counts reach the Dictation tab's line, the model row and the menu bar (F859)")
func theHelpersByteCountsReachTheStatusText() async throws {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("F859-helper-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let release = scratch.appendingPathComponent("release")
    let script = scratch.appendingPathComponent("helper.sh")
    try """
    printf '{"downloading":true}\\n'
    printf '{"downloading":true,"downloadedBytes":677870710,"totalBytes":1613977880}\\n'
    i=0; while [ -d "\(scratch.path)" ] && [ ! -e "\(release.path)" ] && [ $i -lt 1200 ]; do i=$((i+1)); sleep 0.05; done
    printf '{"downloading":false}\\n'
    printf '{"ready":true}\\n'
    IFS= read -r request
    """.write(to: script, atomically: true, encoding: .utf8)
    let engine = WarmWhisperDictationEngine(
        python: URL(fileURLWithPath: "/bin/sh"), script: script, modelDirectory: scratch
    )
    let rig = try DownloadSurfaceRig(engine: engine)
    defer { try? Data().write(to: release); rig.cleanUp() }

    #expect(rig.controller.modelDownloadNoticeText == DictationController.modelDownloadNotice)
    rig.controller.warmUpIfNeeded() // enabling, or launch with dictation on
    try await rig.waitUntil("the figure to reach the controller") {
        rig.controller.modelDownloadProgress?.percent == 42
    }

    let size = ByteCountFormatter.string(fromByteCount: 1_613_977_880, countStyle: .file)
    #expect(rig.controller.modelDownloadNoticeText.contains("42 % of \(size)"), "\(rig.controller.modelDownloadNoticeText)")
    #expect(rig.controller.modelDownloadRowText.hasSuffix("42 %"))
    #expect(rig.controller.modelDownloadMenuText.hasSuffix("42 %"))

    try Data().write(to: release)
    try await rig.waitUntil("the download to end") { !rig.controller.isDownloadingModel }
    #expect(rig.controller.modelDownloadProgress == nil, "an ended download keeps no figure")
    #expect(rig.controller.modelDownloadNoticeText == DictationController.modelDownloadNotice)
}

@MainActor
@Test("The Dictation tab, its model row and the menu bar show the download's figure (F859)")
func theDownloadFigureIsShownWhereTheUserLooks() throws {
    let view = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/DictationView.swift")
    #expect(view.contains("Text(dictation.modelDownloadNoticeText)"))
    #expect(view.contains("Text(dictation.modelDownloadRowText)"))
    let entry = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppEntry.swift")
    #expect(entry.contains("Text(dictation.modelDownloadMenuText)"))
}
