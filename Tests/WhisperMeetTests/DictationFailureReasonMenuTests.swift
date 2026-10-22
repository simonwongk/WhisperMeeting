import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

/// F687 — a failed dictation's pill says "Dictation failed" for 1.6 s and not why. VoiceOver hears
/// the reason (F537); a sighted user found it only in the Dictation tab's history, a window away.
/// The reason now stays in the menu-bar menu, under Quick Dictation, until a later dictation ends
/// without failing or Quick Dictation is switched off. `status` still goes back to idle with the
/// pill: in the menu bar its error icon means a trigger that cannot be armed, not one dictation that
/// failed.

@MainActor
private final class PillLog: DictationOverlayPresenting {
    private(set) var shown: [DictationOverlay.Phase] = []
    private(set) var hides = 0
    func show(_ phase: DictationOverlay.Phase) { shown.append(phase) }
    func update(level: Float) {}
    func hide() { hides += 1 }
}

private struct MicrophoneRefused: LocalizedError {
    var errorDescription: String? { "The test microphone refused to start." }
}

/// A real controller with fakes for everything but the failure path under test.
@MainActor
private struct Rig {
    let controller: DictationController
    let monitor = FakeHotkeyMonitor()
    let recorder: FakeDictationRecorder
    let pill = PillLog()
    let cleanUp: () -> Void

    init(engine: DictationEngine = EmptyDictationEngine()) throws {
        let suite = testSuiteName()
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationFailureReasonMenu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults.set(true, forKey: "dictationEnabled")
        defaults.set(false, forKey: "dictationAutoPaste")
        recorder = FakeDictationRecorder(outputURL: directory.appendingPathComponent("clip.wav"))
        controller = DictationController(
            defaults: defaults,
            engine: engine,
            recorder: recorder,
            overlay: pill,
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
        controller.gpuUtilization = { nil }
        cleanUp = {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// A dictation that fails: the audio device changes under it (F357).
    func failADictation() async throws {
        monitor.onPressStart?()
        try #require(controller.status == .listening)
        recorder.simulateCaptureInterruption(.deviceConfigurationChanged)
        try await waitUntil("the dictation to fail") {
            if case .error = controller.status { true } else { false }
        }
    }

    /// Polls `condition` under a 30 s cap and requires it (F645).
    func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = SuspendingClock.now + .seconds(30)
        while !condition(), SuspendingClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition(), "timed out waiting for \(what)")
    }
}

private let interrupted = DictationCaptureInterruption.deviceConfigurationChanged.message

@MainActor
@Test("A failed dictation's reason stays for the menu bar after its pill has gone, and its status does not stay at error (F687)")
func aFailuresReasonOutlivesItsPill() async throws {
    let rig = try Rig()
    defer { rig.cleanUp() }
    #expect(rig.controller.lastFailureReason == nil)
    #expect(rig.controller.lastFailureMenuText == nil, "the menu bar names a failure before any dictation")

    try await rig.failADictation()
    #expect(rig.controller.lastFailureReason == interrupted, "the failure's reason was not kept")

    // The pill goes after 1.6 s, and the status with it: back to idle, not kept at `.error`.
    try await rig.waitUntil("the failure's pill to go") { rig.pill.hides > 0 && rig.controller.status == .idle }
    #expect(rig.controller.lastFailureReason == interrupted, "the reason went with the pill")
    #expect(rig.controller.lastFailureMenuText == DictationController.lastFailureMenuLine(reason: interrupted))
}

@MainActor
@Test("The reason stays through presses that dictate nothing, and goes when a later dictation is delivered (F687)")
func aDeliveredDictationClearsTheReason() async throws {
    let rig = try Rig(engine: FixedTextDictationEngine(text: "dictated words"))
    defer { rig.cleanUp() }
    try await rig.failADictation()
    try #require(rig.controller.lastFailureReason == interrupted)

    // A press refused while the microphone is busy dictates nothing.
    rig.controller.configure(isMicrophoneBusy: { true })
    rig.monitor.onPressStart?()
    #expect(rig.controller.lastFailureReason == interrupted, "a refused press cleared the reason")
    rig.controller.configure(isMicrophoneBusy: { false })

    // Nor does a press that was half of a shortcut (F448), dropped unheard...
    rig.monitor.onPressStart?()
    try #require(rig.controller.status == .listening)
    rig.monitor.onPressCancel?()
    try #require(rig.controller.status == .idle)
    #expect(rig.controller.lastFailureReason == interrupted, "a shortcut's press cleared the reason")

    // ...or a tap too short to be a dictation.
    rig.recorder.stopDuration = 0.1
    rig.monitor.onPressStart?()
    rig.monitor.onPressEnd?()
    try #require(rig.controller.status == .idle)
    #expect(rig.controller.lastFailureReason == interrupted, "a tap too short to dictate cleared the reason")

    // A dictation that is delivered is the last dictation now, and it did not fail.
    rig.recorder.stopDuration = 1
    rig.monitor.onPressStart?()
    rig.monitor.onPressEnd?()
    try await rig.waitUntil("the dictation to be delivered") { rig.pill.shown.last == .copied }
    #expect(rig.controller.lastFailureReason == nil, "a delivered dictation kept the failure before it")
    #expect(rig.controller.lastFailureMenuText == nil)
}

@MainActor
@Test("A later failure replaces the reason, nothing heard clears it, and switching Quick Dictation off clears it (F687)")
func theReasonFollowsTheLastDictation() async throws {
    let rig = try Rig()
    defer { rig.cleanUp() }
    try await rig.failADictation()

    // The next one fails another way: the microphone does not start.
    rig.recorder.startError = MicrophoneRefused()
    rig.monitor.onPressStart?()
    #expect(rig.controller.lastFailureReason == "The test microphone refused to start.", "a later failure kept the earlier reason")
    rig.recorder.startError = nil

    // A dictation that heard nothing did not fail.
    rig.recorder.stopError = MicDictationRecorder.RecorderError.noAudioCaptured
    rig.monitor.onPressStart?()
    rig.monitor.onPressEnd?()
    #expect(rig.controller.lastFailureReason == nil, "a dictation that heard nothing kept the failure before it")
    rig.recorder.stopError = nil

    try await rig.failADictation()
    try #require(rig.controller.lastFailureReason == interrupted)
    rig.controller.setEnabled(false)
    #expect(rig.controller.lastFailureReason == nil, "switching Quick Dictation off kept the reason")
    #expect(rig.controller.lastFailureMenuText == nil)
}

@Test("The menu line is the reason's first line, cut at a word when a menu could not hold it (F687)")
func theMenuLineIsTheReasonsFirstLine() {
    let short = "Microphone permission is off."
    #expect(DictationController.lastFailureMenuLine(reason: short) == "Last dictation failed: \(short)")

    // A helper's failure carries its stderr after the first line (`WarmWhisperDictationEngine`); only the
    // first line is ever shown, cut at a word when it is longer than the menu's 60 characters (F924).
    let withStderr = "Local transcription failed: Dictation helper stopped unexpectedly.\nTraceback (most recent call last):\n  File \"helper.py\", line 1"
    #expect(
        DictationController.lastFailureMenuLine(reason: withStderr)
            == "Last dictation failed: Local transcription failed: Dictation helper stopped…"
    )

    let long = String(repeating: "word ", count: 80)
    let cut = DictationController.lastFailureMenuLine(reason: long, limit: 42)
    #expect(cut.hasSuffix("word…"), "a long reason was not cut at a word: \(cut)")
    #expect(cut.count <= "Last dictation failed: ".count + 42, "\(cut.count) characters")

    let url = "HTTP 403 downloading https://example.invalid/" + String(repeating: "a", count: 300)
    let unbroken = DictationController.lastFailureMenuLine(reason: url, limit: 42)
    #expect(unbroken.hasSuffix("…") && unbroken.count <= "Last dictation failed: ".count + 42, "\(unbroken)")

    // Nothing to name: no colon left hanging.
    #expect(DictationController.lastFailureMenuLine(reason: " \n ") == "Last dictation failed")
}

/// The menu-bar menu is a SwiftUI scene no test can render (F174), so its source is asserted, with
/// comments stripped (F285): the reason is shown in the dictation section, under the Quick Dictation
/// toggle and before Settings.
@Test("The menu-bar menu shows the last failure's reason under Quick Dictation (F687)")
func theMenuBarShowsTheLastFailure() throws {
    let entry = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppEntry.swift")
    let menu = try #require(entry.range(of: "struct RecordingMenu: View {"))
    let menuEnd = try #require(entry.range(of: "struct RecordingCommands", range: menu.upperBound..<entry.endIndex))
    let body = entry[menu.upperBound..<menuEnd.lowerBound]
    let toggle = try #require(body.range(of: "Toggle(\"Quick Dictation\""))
    let shown = try #require(
        body.range(of: "if let failure = dictation.lastFailureMenuText {"),
        "the menu bar does not show the last failure's reason"
    )
    let text = try #require(body.range(of: "Text(failure)"))
    let settings = try #require(body.range(of: "SettingsLink"))
    #expect(toggle.upperBound <= shown.lowerBound, "the reason is not under the Quick Dictation toggle")
    #expect(shown.upperBound <= text.lowerBound)
    #expect(text.upperBound <= settings.lowerBound, "the reason is not in the dictation section")
}

// F924 — the user's decision of 2026-10-17: a short line in the menu, the full reason in the Dictation history.
// The longest known reason is the download stall's, the likeliest first-run failure: 171 characters, 194 with the
// prefix, which made a menu 1,212 pt wide.
@Test("The download stall's reason, the longest known, is a short menu line cut at a word (F924)")
func theLongestKnownReasonIsAShortMenuLine() {
    let stall = "The dictation model download made no progress for 180 seconds and was stopped. "
        + "Check your connection and try again; a download continues from where it stopped when it can."
    try? #require(stall.count == 171)
    let line = DictationController.lastFailureMenuLine(reason: stall)
    #expect(line == "Last dictation failed: The dictation model download made no progress for 180…", "\(line)")
    #expect(line.count <= "Last dictation failed: ".count + 60, "\(line.count) characters")
    // The device-change sentence a dictation is cut short by, shortened the same way and never mid-word.
    let device = DictationController.lastFailureMenuLine(reason: interrupted)
    #expect(device.count <= "Last dictation failed: ".count + 60, "\(device)")
    if interrupted.count > 60 {
        #expect(device.hasSuffix("…"), "\(device)")
        let shownWords = device.dropFirst("Last dictation failed: ".count).dropLast().split(separator: " ")
        #expect(interrupted.split(separator: " ").starts(with: shownWords), "cut mid-word: \(device)")
    }
}
