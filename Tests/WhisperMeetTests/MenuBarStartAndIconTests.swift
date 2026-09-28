import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F543 — the menu bar misstated the app, three ways:
//
// 1. Its Start Recording was greyed for the whole of every transcription, which `startRecording()`
//    does not refuse — the record screen and ⌘R both started a recording then — while ⌘R stayed
//    live in states where `startRecording()` returns without a word.
// 2. Nothing showed a healthy recording with no window open: the icon was the dictation "mic" whether
//    a meeting was being recorded or not, so a refused Start looked exactly like a working one.
// 3. Help ▸ Keyboard Shortcuts (⌘/) only set a flag that a sheet on the window presented, so with no
//    window it did nothing, and the latched flag popped the sheet over the next window — in every
//    window — hours later.
//
// Parts 1 and 2 are asked of the same functions the menu bar renders from (`RecordingMenu
// .presentation`, `WhisperMeetApp.menuBarSymbol`, `RecordingCommands.state`), over a real model.
// Part 3 is scene wiring this target cannot render (F174) and is pinned by source.

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

/// Holds a stubbed engine open so "a transcription is running" is a state the test controls.
private actor Latch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@MainActor
private func makeModel(_ label: String) throws -> (AppModel, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F543-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(
            stoppingCapture: {}, finishingTracks: {}, preservingPartialTracks: {},
            startingCapture: { _, _, _ in }, directory: root
        ),
        defaults: UserDefaults(suiteName: "F543.\(label).\(UUID().uuidString)")!,
        whisperExecutable: { URL(fileURLWithPath: "/tmp/whisper-stub") },
        qwenInstalled: { true }
    )
    return (model, root)
}

/// Polls the assertion's own subject against the wall clock, and requires it.
@MainActor
private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(30)
    while !condition(), Date() < deadline {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    try #require(condition(), "timed out waiting for \(what)")
}

private let atRisk = RecordingHealthSnapshot(
    microphoneLevel: RecordingAudioLevel(rms: 0, peak: 0),
    systemAudioLevel: RecordingAudioLevel(rms: 0, peak: 0),
    availableStorageBytes: nil, warnings: [.microphoneCaptureStopped]
)

// MARK: - Part 1: one start rule

@MainActor
@Test("During a transcription the menu bar offers Start, and pressing it starts a recording (F543)")
func menuBarStartIsOfferedDuringATranscription() async throws {
    let (model, root) = try makeModel("transcribing")
    defer { try? FileManager.default.removeItem(at: root) }
    let latch = Latch()
    model.runTranscriptionEngineOverride = { _, _ in
        await latch.wait()
        return TranscriptionResult(id: "x", text: "Done.", languageCode: "en", audioDuration: 2,
                                   confidence: nil, segments: [seg("Done.", 0, 2)])
    }
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: folder.appendingPathComponent("meeting.wav"))
    model.store.upsert(MeetingRecord(id: id, title: "Meeting 1", recordingPath: "Recordings/\(id.uuidString)/meeting.wav"))
    model.beginTranscription(id: id)
    try #require(model.hasActiveTranscription, "the latched transcription is not running")

    // The back-to-back case: meeting 1 is transcribing, meeting 2 is starting.
    #expect(model.canStartRecording, "a transcription is not a reason startRecording refuses")
    #expect(RecordingMenu.presentation(for: model).startEnabled,
            "the menu bar greyed Start for the whole transcription")
    let toggle = try #require(CommandCatalog.all.first { $0.id == "toggleRecording" })
    #expect(toggle.enablement.isEnabled(RecordingCommands.state(for: model)))

    await model.startRecording()
    #expect(model.recordingState.isLive, "an enabled Start must actually start")

    await model.cancelRecording()
    await latch.open()
    try await waitUntil("the latched transcription to finish") { !model.hasActiveTranscription }
}

@MainActor
@Test("The menu bar's Start and ⌘R agree with the one start rule in every recording phase (F543)")
func everyStartSurfaceReadsTheOneRule() throws {
    let (model, root) = try makeModel("phases")
    defer { try? FileManager.default.removeItem(at: root) }
    let toggle = try #require(CommandCatalog.all.first { $0.id == "toggleRecording" })
    let phases: [AppModel.RecordingState] = [.idle, .starting, .recording(startedAt: Date()), .stopping]
    for phase in phases {
        model.setRecordingStateForTesting(phase)
        let menu = RecordingMenu.presentation(for: model)
        #expect(menu.startEnabled == model.canStartRecording, "menu bar Start disagrees with the rule in \(phase)")
        // ⌘R is a toggle: it stops whatever is running, and otherwise starts under the same rule.
        #expect(toggle.enablement.isEnabled(RecordingCommands.state(for: model))
                    == (model.isRecordingActive || model.canStartRecording), "⌘R in \(phase)")
    }
    model.setRecordingStateForTesting(.idle)
    #expect(model.canStartRecording)
}

@MainActor
@Test("A Start refused while no window is open reaches the windowless channel (F543)")
func aRefusedStartReachesAUserWithNoWindow() async throws {
    let (model, root) = try makeModel("refused")
    defer { try? FileManager.default.removeItem(at: root) }
    // Quick Dictation owns the microphone: a refusal that explains itself, so Start stays enabled.
    model.configureDictationGuard { true }
    #expect(RecordingMenu.presentation(for: model).startEnabled)

    await model.startRecording()

    #expect(model.recordingState == .idle)
    let offered = try #require(model.lastWindowlessMessage,
                               "the refusal was set on the window's alert only, which nobody sees from the menu bar")
    #expect(offered.contains("Quick Dictation"))
}

// MARK: - Part 2: the icon shows a recording

@MainActor
@Test("The menu-bar icon shows a recording is running, and at risk still outranks it (F543)")
func menuBarIconShowsARecording() throws {
    let (model, root) = try makeModel("icon")
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(WhisperMeetApp.menuBarSymbol(for: model, dictationStatus: .idle) == "mic")

    model.setRecordingStateForTesting(.starting)
    #expect(WhisperMeetApp.menuBarSymbol(for: model, dictationStatus: .idle) == "record.circle.fill",
            "a start that was accepted must look different from one that was refused")
    model.setRecordingStateForTesting(.recording(startedAt: Date()))
    #expect(WhisperMeetApp.menuBarSymbol(for: model, dictationStatus: .idle) == "record.circle.fill",
            "a healthy recording looked exactly like no recording")

    model.setRecordingHealthForTesting(atRisk)
    #expect(WhisperMeetApp.menuBarSymbol(for: model, dictationStatus: .idle) == "exclamationmark.triangle.fill",
            "a recording losing audio still takes the icon first (F294)")

    model.setRecordingStateForTesting(.stopping)
    #expect(WhisperMeetApp.menuBarSymbol(for: model, dictationStatus: .idle) == "record.circle.fill",
            "finishing is still the recording, and its last snapshot is stale (F337)")

    model.setRecordingStateForTesting(.idle)
    model.setRecordingHealthForTesting(nil)
    #expect(WhisperMeetApp.menuBarSymbol(for: model, dictationStatus: .listening) == "mic.fill",
            "with no recording the icon is dictation's again")
}

// MARK: - Source pins for what this target cannot render (F174)

@Test("The record screen's Start and the menu bar's Start both read AppModel.canStartRecording (F543)")
func bothStartControlsReadTheSharedRule() throws {
    let entry = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppEntry.swift")
    #expect(entry.contains("canStartRecording: model.canStartRecording"),
            "the menu bar and ⌘R must be handed the shared rule")
    #expect(!entry.contains("isMicrophoneBusy: model.isMicrophoneBusy,"),
            "the menu bar must not derive Start from inputs of its own")

    let content = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let recordStart = try #require(content.range(of: "private struct RecordMeetingView: View {"))
    let recordView = content[recordStart.lowerBound...]
    let busy = try #require(recordView.range(of: "private var isPrimaryActionBusy: Bool {"))
    #expect(recordView[busy.upperBound...].prefix(400).contains("case .idle: return !model.canStartRecording"),
            "the record screen's Start must be greyed by the same rule as the menu bar's")
}

@Test("Keyboard Shortcuts opens its own window, so it works with no window and never latches (F543)")
func keyboardShortcutsOpensItsOwnWindow() throws {
    let entry = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppEntry.swift")
    let body = try #require(entry.range(of: "var body: some Scene {"))
    #expect(entry[body.upperBound...].contains("Window(KeyboardShortcutsView.windowTitle, id: KeyboardShortcutsView.windowID)"),
            "the shortcuts need a scene of their own; a sheet needs a window to hang from")
    let commands = try #require(entry.range(of: "struct RecordingCommands: Commands {"))
    let route = try #require(entry[commands.upperBound...].range(of: "case \"keyboardShortcuts\":"))
    #expect(entry[route.upperBound...].prefix(120).contains("openWindow(id: KeyboardShortcutsView.windowID)"))

    // The latch itself must be gone: a flag nothing presents is how the sheet appeared hours later.
    for file in ["Sources/WhisperMeet/AppEntry.swift", "Sources/WhisperMeet/AppModel.swift",
                 "Sources/WhisperMeet/ContentView.swift"] {
        #expect(!(try SourceAssertion.uncommentedSource(file)).contains("showsShortcutsSheet"), "\(file)")
    }
}
