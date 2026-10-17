import Foundation
import ServiceManagement
import WhisperCore

/// The app's login item (`SMAppService.mainApp`), as a seam so a test can switch it without
/// registering the real app (F792).
struct LoginItemControl {
    var isEnabled: @MainActor () -> Bool
    var setEnabled: @MainActor (Bool) throws -> Void

    /// The real login item. In a test process it reads as off and refuses to change, so a test that
    /// forgot the seam cannot register the developer's own build to launch at login.
    static let mainApp = LoginItemControl(
        isEnabled: {
            guard TestProcess.allowsRealAccess(to: "login item") else { return false }
            return SMAppService.mainApp.status == .enabled
        },
        setEnabled: { enabled in
            guard TestProcess.allowsRealAccess(to: "login item") else { throw CocoaError(.featureUnsupported) }
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        }
    )
}

extension AppModel {
    /// Settings' Launch at login switch (F792, F749). Returns the state the switch should show.
    ///
    /// A refusal goes through `report(_:)`, not `alertMessage` (F792): Settings is a window of its
    /// own, open with ⌘, when no library window — the only host of `alertMessage`'s alert — may
    /// exist, and the switch then snapped back with nothing said (F257's rule).
    ///
    /// In a library moved by `WHISPERMEET_LIBRARY` it does nothing (F749): the login item is the app
    /// bundle's, so a rehearsal copy switching it switched the real app's, which then launched at
    /// login against the real library. The switch is disabled there too; this is the refusal behind
    /// it, so nothing else that calls this can do it either.
    ///
    /// A successful change shows what was asked, not what `isEnabled` reads afterwards: a registration
    /// that macOS holds for the user's approval in System Settings reads as not enabled, and turning
    /// the switch back off under them would hide that it is waiting there.
    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        guard !libraryIsMoved else { return loginItem.isEnabled() }
        do {
            try loginItem.setEnabled(enabled)
            return enabled
        } catch {
            report("Could not update launch-at-login: \(ErrorPresentation.readable(error))")
            return loginItem.isEnabled()
        }
    }
}
