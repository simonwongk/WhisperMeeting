import SwiftUI
import ServiceManagement

@main
struct WhisperMeetApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var dictation = DictationController()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, dictation: dictation)
                .frame(minWidth: 900, minHeight: 620)
                .task {
                    dictation.configure(isMicrophoneBusy: { [weak model] in model?.isMicrophoneBusy ?? false })
                    dictation.configureVocabulary { [weak model] in model?.store.vocabulary ?? [] }
                    model.configureDictationGuard { dictation.isActive }
                    await model.performStartupRecovery()
                }
        }
        .defaultSize(width: 1_100, height: 760)
        .windowToolbarStyle(.unified)

        MenuBarExtra("WhisperMeet Dictation", systemImage: menuBarSymbol) {
            DictationMenu(dictation: dictation)
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

private struct DictationMenu: View {
    @ObservedObject var dictation: DictationController

    var body: some View {
        Toggle("Quick Dictation", isOn: Binding(
            get: { dictation.enabled },
            set: { dictation.setEnabled($0) }
        ))
        Divider()
        SettingsLink { Text("Settings…") }
        Button("Quit WhisperMeet") { NSApplication.shared.terminate(nil) }
    }
}
