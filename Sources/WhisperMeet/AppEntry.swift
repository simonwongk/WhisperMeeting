import SwiftUI

@main
struct WhisperMeetApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 620)
                .task {
                    model.refreshRuntime()
                    model.recoverInterruptedTranscriptions()
                }
        }
        .defaultSize(width: 1_100, height: 760)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView(model: model)
                .frame(width: 520)
                .padding(24)
        }
    }
}
