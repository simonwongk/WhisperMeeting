import SwiftUI
import WhisperCore

/// The Cancel beside an install's progress line (F520). It stops the installer's whole process
/// group; the script puts back what it was replacing, and the row then says whether a previous
/// version was kept. Disabled, reading "Cancelling…", while that restore runs.
struct InstallCancelButton: View {
    @ObservedObject var model: AppModel
    let component: ModelInstallComponent

    var body: some View {
        Button(model.isCancellingInstall(component) ? "Cancelling…" : "Cancel") {
            model.cancelInstall(component)
        }
        .disabled(model.isCancellingInstall(component))
        .help("Stop the download. Anything already installed is put back as it was.")
    }
}
