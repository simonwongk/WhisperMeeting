import SwiftUI
import WhisperCore

/// The Cancel beside an install's progress line (F520). It stops the installer's whole process
/// group; the script puts back what it was replacing, and the row then says whether a previous
/// version was kept — unless the installer had already switched the new version in, in which case
/// it finishes and the row says it is ready (F654). Disabled, reading "Cancelling…", meanwhile.
struct InstallCancelButton: View {
    @ObservedObject var model: AppModel
    let component: ModelInstallComponent

    var body: some View {
        Button(model.isCancellingInstall(component) ? "Cancelling…" : "Cancel") {
            model.cancelInstall(component)
        }
        .disabled(model.isCancellingInstall(component))
        .help("Stop the install. Until the new version is switched in, what was installed before stays as it was; after that, the install finishes.")
    }
}
