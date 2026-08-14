import SwiftUI
import ServiceManagement
import WhisperCore

@main
struct WhisperMeetApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var dictation = DictationController()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, dictation: dictation)
                .frame(minWidth: 900, minHeight: 620)
                // Flush any pending debounced transcript/notes edit on quit or when the app resigns
                // active, so the last edit isn't lost within the debounce window (F138).
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.flushPendingWrites()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
                    model.flushPendingWrites()
                }
                .task {
                    dictation.configure(isMicrophoneBusy: { [weak model] in
                        model?.isMicrophoneBusy ?? false
                    })
                    // Distinct from a microphone conflict: pause dictation while a meeting model
                    // runtime installs so the two don't contend for CPU/memory (F37).
                    dictation.configureRuntimeInstalling { [weak model] in
                        model?.isInstallingRecognitionRuntime ?? false
                    }
                    // Quick Dictation feeds this straight into Whisper's `initial_prompt` (and derives
                    // its prompt-echo check from the same list), so it takes the prompt-capped view —
                    // the stored list is no longer trimmed to a prompt budget (F187).
                    dictation.configureVocabulary { [weak model] in model?.store.promptVocabulary ?? [] }
                    model.configureDictationGuard { dictation.isActive }
                    await model.performStartupRecovery()
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
    }

    private var menuBarSymbol: String {
        switch dictation.status {
        case .listening: "mic.fill"
        case .transcribing, .delivering: "waveform"
        case .error: "mic.slash"
        default: "mic"
        }
    }
}

/// The menu-bar menu: live recording status + controls (Start / Stop & Transcribe / Add Marker /
/// Cancel) rendered from the tested `MenuBarRecording` presentation core, above the dictation and app
/// items (F80, delivers F62).
private struct RecordingMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var dictation: DictationController

    private func elapsedSeconds() -> TimeInterval {
        if case let .recording(startedAt) = model.recordingState {
            return Date().timeIntervalSince(startedAt)
        }
        return 0
    }

    var body: some View {
        let presentation = MenuBarRecording.make(
            isRecording: model.isRecordingActive,
            isStopping: model.recordingState == .stopping,
            elapsedSeconds: elapsedSeconds(),
            isMicrophoneBusy: model.isMicrophoneBusy,
            hasActiveTranscription: model.hasActiveTranscription
        )
        Text(presentation.statusTitle)
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
private struct RecordingCommands: Commands {
    @ObservedObject var model: AppModel

    private var state: AppCommandState {
        AppCommandState(isRecording: model.isRecordingActive, isTranscribing: model.hasActiveTranscription)
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
            model.showsShortcutsSheet = true
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

/// A read-only reference sheet listing every command and its shortcut, from the single
/// `CommandCatalog` source (F85).
struct KeyboardShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

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
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 380, height: 340)
    }
}
