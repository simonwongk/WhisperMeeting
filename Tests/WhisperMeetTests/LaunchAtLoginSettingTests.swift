import Foundation
import os
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F792 — Settings' Launch at login set `model.alertMessage` directly when `SMAppService` refused. That
// alert's host is the library window's, and Settings is also a window of its own (⌘, with no library
// window open), where the switch snapped back with nothing said. It now goes through `report(_:)`.
//
// F749 — the login item is the app bundle's, not a library's. A rehearsal copy started with
// `WHISPERMEET_LIBRARY` switched it for the real app, which then launched at login against the real
// library. The switch is disabled in a moved library, and the model refuses too.
//
// F746 — the summary style and template were `@AppStorage` with no store, so a rehearsal copy read and
// wrote the real library's (`.standard`) while everything else followed `WhisperMeetLibrary.defaults()`.

@MainActor
private final class Posted {
    var bodies: [String] = []
}

/// A login item that refuses every change, counting the attempts.
@MainActor
private final class RefusingLoginItem {
    var attempts = 0
    var control: LoginItemControl {
        LoginItemControl(
            isEnabled: { false },
            setEnabled: { [unowned self] _ in
                attempts += 1
                throw NSError(domain: "SMAppServiceErrorDomain", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
            }
        )
    }
}

@MainActor
private func makeModel() throws -> (AppModel, Posted, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F792-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    // Settings open on its own, with no library window.
    model.windowFacts = { (windows: [], appIsActive: true) }
    let posted = Posted()
    model.deliverUserNotification = { _, body in posted.bodies.append(body) }
    model.libraryIsMoved = false
    return (model, posted, root)
}

@MainActor
@Test("A refused Launch at login is said with no library window open (F792)")
func launchAtLoginFailureReachesAWindowlessSettings() throws {
    let (model, posted, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let item = RefusingLoginItem()
    model.loginItem = item.control

    let shown = model.setLaunchAtLogin(true)

    #expect(item.attempts == 1)
    #expect(shown == false, "the switch shows what the login item says after a refusal")
    #expect(posted.bodies.count == 1, "nothing reached a user with only Settings open: \(posted.bodies)")
    #expect(posted.bodies.first?.contains("Could not update launch-at-login") == true, "\(posted.bodies)")
    #expect(posted.bodies.first?.contains("Operation not permitted") == true, "\(posted.bodies)")
}

@MainActor
@Test("A rehearsal copy never switches the real app's login item (F749)")
func movedLibraryLeavesTheLoginItemAlone() throws {
    let (model, posted, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let item = RefusingLoginItem()
    model.loginItem = item.control
    model.libraryIsMoved = true

    let shown = model.setLaunchAtLogin(true)

    #expect(item.attempts == 0, "a moved library registered or unregistered the app's login item")
    #expect(shown == false)
    #expect(posted.bodies.isEmpty && model.alertMessage == nil, "the switch is disabled; there is nothing to say")
}

@Test("A library is moved exactly when WHISPERMEET_LIBRARY names an absolute path (F749)")
func isMovedFollowsTheLibraryPredicate() {
    #expect(WhisperMeetLibrary.isMoved(environment: ["WHISPERMEET_LIBRARY": "/tmp/rehearsal"]))
    #expect(!WhisperMeetLibrary.isMoved(environment: [:]))
    #expect(!WhisperMeetLibrary.isMoved(environment: ["WHISPERMEET_LIBRARY": "relative/path"]))
    #expect(!WhisperMeetLibrary.isMoved(environment: ["WHISPERMEET_LIBRARY": "  "]))
    // The same answer the settings domain gives, by construction.
    for environment in [["WHISPERMEET_LIBRARY": "/tmp/rehearsal"], [:]] {
        #expect(WhisperMeetLibrary.isMoved(environment: environment)
            == (WhisperMeetLibrary.defaultsSuiteName(environment: environment) != nil))
    }
}

/// `SettingsView`'s body, comments stripped.
private func settingsViewSource() throws -> String {
    let content = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let start = try #require(content.range(of: "struct SettingsView: View {"))
    let end = try #require(content.range(of: "\nprivate struct ", range: start.upperBound..<content.endIndex))
    return String(content[start.lowerBound..<end.lowerBound])
}

@Test("Settings reports through the model, never by setting alertMessage itself (F792)")
func settingsViewSetsNoAlertMessageDirectly() throws {
    let settings = try settingsViewSource()
    #expect(!settings.contains("model.alertMessage ="),
            "SettingsView assigns model.alertMessage; Settings can be open with no window to show it")
    #expect(settings.contains("model.setLaunchAtLogin("))
}

@Test("The Launch at login switch is disabled in a moved library (F749)")
func launchAtLoginSwitchIsGatedOnTheMovedLibrary() throws {
    let settings = try settingsViewSource()
    let toggle = try #require(settings.range(of: "Toggle(\"Launch at login\""))
    let around = settings[toggle.lowerBound...].prefix(600)
    // F1088 added "|| !launchAtLoginKnown" to the same expression: still gated on the moved library.
    #expect(around.contains(".disabled(model.libraryIsMoved"), "\(around)")
}

@Test("Every @AppStorage in the app uses the library's own store, so a moved library keeps its own settings (F746)")
func everyAppStorageNamesItsStore() throws {
    var offenders: [String] = []
    var found = 0
    for url in try SourceAssertion.swiftFileURLs(under: "Sources/WhisperMeet") {
        let code = SourceAssertion.stripComments(try String(contentsOf: url, encoding: .utf8))
        var searchFrom = code.startIndex
        while let match = code.range(of: "@AppStorage(", range: searchFrom..<code.endIndex) {
            found += 1
            // The wrapper's argument list, to its closing parenthesis.
            let arguments = code[match.upperBound...].prefix { $0 != ")" }
            // Round 2 (the review's finding 6): naming a store is not enough — `store: .standard` names
            // one and is the shared domain this guard exists to keep out. The library's own is required.
            let store = arguments.range(of: "store:").map {
                arguments[$0.upperBound...].trimmingCharacters(in: .whitespaces)
            }
            if store != "libraryDefaults" {
                offenders.append("\(url.lastPathComponent): @AppStorage(\(arguments))")
            }
            searchFrom = match.upperBound
        }
    }
    #expect(found >= 2, "the scan must find the summary style and template (\(found))")
    #expect(offenders.isEmpty, "these do not use libraryDefaults, so they read a shared domain under WHISPERMEET_LIBRARY:\n\(offenders.joined(separator: "\n"))")
}

// F1088, F1089 — `SettingsView` read `SMAppService.mainApp.status` in two `@State` initial values. SwiftUI
// evaluates an initial value every time the view is constructed, and the Settings scene's view is constructed on
// every re-evaluation of `WhisperMeetApp.body` — every dictation phase, every model change — whether Settings is
// open or not. Each read is an XPC round trip to smd, measured at 0.3–0.5 s on the user's Mac (a 30 s sample on
// 2026-10-23: 1,374 samples in `WhisperMeetApp.body`, 753 + 621 of them in `SMAppService.status` under
// `SettingsView.init`), so the main thread stalled for about a second at a time: a press waited 982 ms to be
// handled, and every pill frame came late. The status is now read once Settings is on screen, off the main thread.
@Test("Settings constructs without asking the system for the login item; the model reads it off the main thread (F1088)")
@MainActor
func launchAtLoginIsReadOffTheMainThreadAndNotWhileConstructing() async throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(!source.contains("SMAppService"), "a view asks the system for the login item while it is constructed")
    #expect(source.contains("readLaunchAtLogin()"), "Settings reads the login item through the model")

    let (model, _, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let readOnMain = OSAllocatedUnfairLock<Bool?>(initialState: nil)
    model.loginItem = LoginItemControl(
        isEnabled: { readOnMain.withLock { $0 = Thread.isMainThread }; return true },
        setEnabled: { _ in }
    )
    #expect(await model.readLaunchAtLogin() == true)
    #expect(readOnMain.withLock { $0 } == false, "the read blocked the main thread")
}
