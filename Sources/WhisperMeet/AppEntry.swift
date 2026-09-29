import SwiftUI
import ServiceManagement
import WhisperCore

/// The process entry point.
///
/// It exists only so `Scripts/setup-speaker-diarization.sh` can call this executable back to prove
/// the speaker-analysis models it just staged actually load and run before it activates them
/// (F216). Nothing on a stock Mac can load a Core ML bundle from a shell, and the diarizer is no
/// longer a separate binary the installer could run — it is a library inside this app — so the app
/// is the only program that can answer the question.
///
/// Every ordinary launch falls straight through to `WhisperMeetApp.main()`, which is exactly what
/// `@main` on the `App` did before. The smoke-test branch returns `Never` and runs before any
/// SwiftUI scene, `NSApplication`, window, or permission prompt is created, so a headless run never
/// shows a second app in the Dock or touches the user's library.
@main
enum WhisperMeetLauncher {
    static func main() {
        ignoreBrokenPipeSignals()
        if let models = DiarizationInstallSmokeTest.modelsParentDirectory(in: CommandLine.arguments) {
            DiarizationInstallSmokeTest.runAndExit(modelsParentDirectory: models)
        }
        // F214: the one other headless branch, and read-only — it prints counts from a dictation
        // log it is pointed at and exits, before any scene, window or permission prompt exists.
        if let log = DictationRefineReportCommand.logURL(in: CommandLine.arguments) {
            DictationRefineReportCommand.runAndExit(
                logURL: log, since: DictationRefineReportCommand.since(in: CommandLine.arguments)
            )
        }
        WhisperMeetApp.main()
    }

    /// F486. A write to a pipe nobody reads raises SIGPIPE, and its default action ends the process.
    /// Every warm helper — both dictation engines and the refiner — takes requests on a stdin pipe,
    /// checked only by `process.isRunning` before the write, so a helper that died a moment earlier
    /// took WhisperMeet down with it, and any meeting it was recording. Ignored, the same write
    /// throws EPIPE, which the engines already turn into an ordinary failure.
    ///
    /// Process-wide rather than per pipe, so a pipe or socket added later is covered without anyone
    /// remembering to. The helpers keep the default: Foundation's `Process` and `ProcessGroupRunner`
    /// (`POSIX_SPAWN_SETSIGDEF`) both reset a child's signal dispositions, so an ignored SIGPIPE is
    /// not inherited across the exec.
    static func ignoreBrokenPipeSignals() {
        signal(SIGPIPE, SIG_IGN)
    }
}

struct WhisperMeetApp: App {
    @StateObject private var model: AppModel
    @StateObject private var dictation = DictationController()
    /// App-level, not window-level (F257). The two `onReceive` modifiers that used to carry the
    /// F138 flush, and the `.task` that ran startup recovery, were both on `ContentView` inside the
    /// `WindowGroup` — so with the window closed, quitting from the menu bar lost the last
    /// debounced edit and a launch without a window never recovered anything.
    @StateObject private var lifecycle: AppLifecycle
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var lifecycleDelegate

    /// F465: the F257 wiring below used to happen inside the WindowGroup ContentView's `.task`,
    /// which never runs at all if no window ever appears — a login item (the app offers "Launch at
    /// login" via `SMAppService`), or a window closed before the task ran. `AppLifecycleDelegate`'s
    /// own `applicationDidFinishLaunching` guards on `Self.lifecycle` being non-nil and returns
    /// early otherwise, so that path was dead code in exactly the launches it exists for: it always
    /// found the window's `.task` hadn't run yet.
    ///
    /// This initializer runs to completion before `NSApp` starts and dispatches
    /// `applicationDidFinishLaunching` — the delegate object itself is a property of this struct,
    /// so building it is part of constructing `self`. Wiring the handlers and setting
    /// `AppLifecycleDelegate.lifecycle` here, rather than in the window's `.task`, means the
    /// delegate always finds a handler: whether or not any window ever opens. It also means the
    /// `Task { await lifecycle.runStartupRecoveryOnce() }` that fires recovery is the delegate's own
    /// free-standing one, never one scoped to a SwiftUI `.task` — so closing the window mid-recovery
    /// no longer cancels it out from under `performStartupRecovery` (the F279 growth probe included).
    init() {
        let model = AppModel()
        let lifecycle = AppLifecycle()
        _model = StateObject(wrappedValue: model)
        _lifecycle = StateObject(wrappedValue: lifecycle)

        lifecycle.onFlush = { [weak model] in model?.flushPendingWrites() }
        // F520: Quit stops a running model install; its script restores what it was replacing.
        lifecycle.onTerminate = { [weak model] in model?.cancelAllInstalls() }
        lifecycle.onStartupRecovery = { [weak model] in
            await model?.performStartupRecovery()
        }
        // F181: files from Finder, the Dock, Shortcuts or the Finder service.
        lifecycle.onOpenFiles = { [weak model] urls in
            await model?.importExternalFiles(urls)
        }
        lifecycle.onRejectedFiles = { [weak model] urls in
            let what = urls.count == 1 ? urls[0].lastPathComponent : "those files"
            model?.report("WhisperMeet can only transcribe audio and video: \(what) was not imported.")
        }
        // F529: a quit during a live recording asks first, and Stop & Quit saves the meeting through
        // the ordinary stop before the process ends.
        lifecycle.isRecordingLive = { [weak model] in model?.recordingState.isLive ?? false }
        // F672: and a stop already saving it is waited for rather than killed.
        lifecycle.isRecordingFinishing = { [weak model] in model?.recordingState == .stopping }
        lifecycle.confirmQuitDuringRecording = { QuitDuringRecordingAlert.ask() }
        lifecycle.onStopRecordingForQuit = { [weak model] in
            await model?.stopRecordingBeforeQuit() ?? true
        }
        AppLifecycleDelegate.lifecycle = lifecycle
        AppLifecycleDelegate.flushFilesOpenedBeforeLaunchFinished()
        lifecycle.begin()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, dictation: dictation)
                .frame(minWidth: 900, minHeight: 620)
                .task {
                    dictation.configure(isMicrophoneBusy: { [weak model] in
                        model?.isMicrophoneBusy ?? false
                    })
                    // Distinct from a microphone conflict: pause dictation while a meeting model
                    // runtime installs so the two don't contend for CPU/memory (F37).
                    dictation.configureRuntimeInstalling { [weak model] in
                        model?.isInstallingRecognitionRuntime ?? false
                    }
                    // Meeting ASR and Quick Dictation both use large local models. Keep them
                    // mutually exclusive and release idle dictation helpers before meeting work
                    // starts, rather than letting unified-memory pressure slow both paths (F206).
                    dictation.configureMeetingTranscriptionRunning { [weak model] in
                        (model?.hasActiveTranscription ?? false)
                            || (model?.isRunningAuxiliaryEngine ?? false)
                    }
                    // Quick Dictation feeds this straight into Whisper's `initial_prompt` (and derives
                    // its prompt-echo check from the same list), so it takes the prompt-capped view —
                    // the stored list is no longer trimmed to a prompt budget (F187).
                    dictation.configureVocabulary { [weak model] in model?.store.promptVocabulary ?? [] }
                    model.configureDictationGuard { dictation.isActive }
                    // F470: a transcription requested during a dictation queues instead of being
                    // refused; this starts it when the dictation ends.
                    dictation.configureActivityEnded { [weak model] in model?.resumeTranscriptionQueue() }
                    model.configureIdleDictationModelRelease { [weak dictation] in
                        await dictation?.releaseIdleModelsForMeetingTranscription()
                    }
                    model.configureIdleDictationRecognitionWarmUp { [weak dictation] in
                        dictation?.warmRecognitionEngineIfNeeded()
                    }
                    // F257/F465: the window still wires the two controllers together above, because
                    // that is view work and both objects outlive it. What it no longer does is any
                    // part of the app-lifecycle wiring — `init()` above sets up `AppLifecycle` and
                    // hands it to `AppLifecycleDelegate` before this `.task` can even run, so startup
                    // recovery, the quit flush and opened files are already live whether or not this
                    // window ever appears.
                }
        }
        .defaultSize(width: 1_100, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
            RecordingCommands(model: model)
        }

        MenuBarExtra("WhisperMeet", systemImage: menuBarSymbol) {
            RecordingMenu(model: model, dictation: dictation)
        }

        Settings {
            SettingsView(model: model, dictation: dictation)
                .frame(width: 520)
                .padding(24)
        }

        // F543: a window of its own rather than a sheet on the library window. The sheet needed a
        // window to hang from, so ⌘/ with none open did nothing and left a flag set that popped the
        // sheet over the next window — in every window — hours later. One scene, opened on demand:
        // it works windowless, cannot latch, and appears once however many library windows exist.
        Window(KeyboardShortcutsView.windowTitle, id: KeyboardShortcutsView.windowID) {
            KeyboardShortcutsView()
        }
        .windowResizability(.contentSize)
        // Help ▸ Keyboard Shortcuts is the way in: not also a Window-menu item, and not a window
        // state restoration brings back by itself at the next launch.
        .commandsRemoved()
        .restorationBehavior(.disabled)
    }

    private var menuBarSymbol: String {
        Self.menuBarSymbol(for: model, dictationStatus: dictation.status)
    }

    /// The menu-bar icon. A function of the model so a test asks it what the icon would be (F543).
    static func menuBarSymbol(for model: AppModel, dictationStatus: DictationController.Status) -> String {
        // F294: a recording losing audio outranks dictation state — it is the one thing in the menu
        // bar that cannot wait, and with no window open the icon is all the user can see.
        if model.isRecordingAtRisk {
            return "exclamationmark.triangle.fill"
        }
        // F543: then the recording itself. The icon used to show dictation state only, so a healthy
        // recording and no recording at all were the same "mic" — and with no window open a refused
        // Start looked exactly like one that worked. Starting and finishing count: from the click to
        // the saved meeting, the recording is what the app is doing. (Neither can start while the
        // other is active — they share the microphone — so what this replaces is at most
        // dictation's idle or error icon.)
        if model.isRecordingActive {
            return "record.circle.fill"
        }
        switch dictationStatus {
        case .listening: return "mic.fill"
        case .transcribing, .delivering: return "waveform"
        case .error: return "mic.slash"
        default: return "mic"
        }
    }
}

/// The menu-bar menu: live recording status + controls (Start / Stop & Transcribe / Add Marker /
/// Cancel) rendered from the tested `MenuBarRecording` presentation core, above the dictation and app
/// items (F80, delivers F62).
struct RecordingMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var dictation: DictationController

    /// What the menu shows, read from the model exactly as `body` reads it — a function so a test
    /// can ask the menu bar's own question rather than restating it (F543).
    static func presentation(for model: AppModel, now: Date = Date()) -> MenuBarRecordingPresentation {
        var elapsed: TimeInterval = 0
        if case let .recording(startedAt) = model.recordingState {
            elapsed = now.timeIntervalSince(startedAt)
        }
        return MenuBarRecording.make(
            isRecording: model.isRecordingActive,
            isStopping: model.recordingState == .stopping,
            elapsedSeconds: elapsed,
            canStartRecording: model.canStartRecording,
            hasActiveTranscription: model.hasActiveTranscription,
            health: model.recordingHealth
        )
    }

    var body: some View {
        let presentation = Self.presentation(for: model)
        Text(presentation.statusTitle)
        if let healthLine = presentation.healthLine {
            Text(healthLine)
        }
        Button(presentation.startTitle) { Task { await model.startRecording() } }
            .disabled(!presentation.startEnabled)
        Button(presentation.stopTitle) { Task { _ = await model.stopRecording(title: "") } }
            .disabled(!presentation.stopEnabled)
        Button("Add Marker") { model.addLiveMarker() }
            .disabled(!presentation.addMarkerEnabled)
        if presentation.cancelEnabled {
            // Cancel is the only destructive path; a menu can't host a confirmation dialog, so require
            // a two-step confirmation via a submenu (presentation.cancelNeedsConfirmation is always true).
            Menu("Cancel Recording…") {
                Button("Discard Recording", role: .destructive) {
                    Task { await model.cancelRecording() }
                }
            }
        }
        Divider()
        Toggle("Quick Dictation", isOn: Binding(
            get: { dictation.enabled },
            set: { dictation.setEnabled($0) }
        ))
        Divider()
        SettingsLink { Text("Settings…") }
        Button("Quit WhisperMeet") { NSApplication.shared.terminate(nil) }
    }
}

/// The app's global keyboard commands (a Recording menu + Help ▸ Keyboard Shortcuts), rendered from the
/// tested `CommandCatalog` so shortcuts have a single source and can't silently collide (F85, F69).
struct RecordingCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    private var state: AppCommandState { Self.state(for: model) }

    /// The state the Recording menu's enablement reads — a function so a test asks it (F543).
    static func state(for model: AppModel) -> AppCommandState {
        AppCommandState(
            isRecording: model.isRecordingActive,
            isTranscribing: model.hasActiveTranscription,
            canStartRecording: model.canStartRecording
        )
    }

    var body: some Commands {
        CommandMenu("Recording") {
            ForEach(CommandCatalog.all.filter { $0.section == "Recording" }) { command in
                commandButton(command)
            }
        }
        CommandGroup(after: .help) {
            ForEach(CommandCatalog.all.filter { $0.section == "Help" }) { command in
                commandButton(command)
            }
        }
    }

    @ViewBuilder
    private func commandButton(_ command: AppCommand) -> some View {
        let button = Button(command.title) { route(command.id) }
            .disabled(!command.enablement.isEnabled(state))
        if let key = command.keyEquivalent {
            button.keyboardShortcut(KeyEquivalent(key), modifiers: eventModifiers(command.modifiers))
        } else {
            button
        }
    }

    private func route(_ id: String) {
        switch id {
        case "toggleRecording":
            if model.isRecordingActive {
                Task { _ = await model.stopRecording(title: "") }
            } else {
                Task { await model.startRecording() }
            }
        case "addMarker":
            model.addLiveMarker()
        case "cancelRecording":
            // Route through the same confirmation as the in-window Cancel button (F139) — never cancel
            // outright, and never prompt when there's nothing to cancel.
            model.requestCancelConfirmation()
        case "keyboardShortcuts":
            openWindow(id: KeyboardShortcutsView.windowID)
        default:
            break
        }
    }

    private func eventModifiers(_ mods: CommandModifiers) -> EventModifiers {
        var result: EventModifiers = []
        if mods.contains(.control) { result.insert(.control) }
        if mods.contains(.option) { result.insert(.option) }
        if mods.contains(.shift) { result.insert(.shift) }
        if mods.contains(.command) { result.insert(.command) }
        return result
    }
}

/// A read-only reference listing every command and its shortcut, from the single `CommandCatalog`
/// source (F85). Shown in a window of its own (F543).
struct KeyboardShortcutsView: View {
    static let windowID = "keyboard-shortcuts"
    static let windowTitle = "Keyboard Shortcuts"

    @Environment(\.dismissWindow) private var dismissWindow

    private var sections: [String] {
        var seen: [String] = []
        for command in CommandCatalog.all where !seen.contains(command.section) { seen.append(command.section) }
        return seen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Keyboard Shortcuts").font(.headline).padding()
            List {
                ForEach(sections, id: \.self) { section in
                    Section(section) {
                        ForEach(CommandCatalog.all.filter { $0.section == section }) { command in
                            HStack {
                                Text(command.title)
                                Spacer()
                                Text(CommandCatalog.displayShortcut(for: command) ?? "—")
                                    .foregroundStyle(.secondary)
                                    .monospaced()
                            }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismissWindow(id: Self.windowID) }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 380, height: 340)
    }
}
