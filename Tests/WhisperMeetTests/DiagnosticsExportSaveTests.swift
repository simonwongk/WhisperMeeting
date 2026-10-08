import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F513 — "Export diagnostics…" wrote with `try? Data(…).write(to: url)` and said nothing either way,
// so a save to an ejected volume, a full disk or a folder the app may not write closed the panel as
// if it had worked. The user then attached nothing, or an old file, to a support request.
//
// Driven through `AppModel.saveDiagnostics(to:)`, the call the Settings button makes. Every model
// here replaces `diagnosticsCrashReports` first (F389), so no test reads the user's own crash
// reports, and `windowFacts`/`deliverUserNotification`, so nothing reaches Notification Centre.

@MainActor
private final class Posted {
    var bodies: [String] = []
}

@MainActor
private func makeModel(_ label: String) -> (AppModel, URL, Posted, () -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F513-\(label)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = testSuiteName()
    let defaults = UserDefaults(suiteName: suite)!
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    model.diagnosticsCrashReports = { [] }
    // Settings open on its own, with no library window: the case where only the windowless channel
    // can reach anyone (F257).
    model.windowFacts = { (windows: [], appIsActive: true) }
    let posted = Posted()
    model.deliverUserNotification = { _, body in posted.bodies.append(body) }
    return (model, root, posted, {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    })
}

@MainActor
@Test("A diagnostics save that cannot be written says so, and leaves no file (F513)")
func diagnosticsSaveFailureIsReported() throws {
    let (model, root, posted, cleanup) = makeModel("unwritable")
    defer { cleanup() }
    // The parent folder does not exist, so the write fails on every host, deterministically.
    let destination = root
        .appendingPathComponent("missing-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("WhisperMeet Diagnostics.json")

    model.saveDiagnostics(to: destination)

    let alert = try #require(model.alertMessage, "a failed save produced no message")
    // The app's own words, not Foundation's: Foundation's sentence depends on the host's locale.
    #expect(alert.hasPrefix("The diagnostics file was not saved."), "\(alert)")
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(posted.bodies.count == 1, "with no library window, the windowless channel carries it: \(posted.bodies)")
}

@MainActor
@Test("A diagnostics save that works writes the bundle and says nothing (F513)")
func diagnosticsSaveSuccessWritesTheBundle() throws {
    let (model, root, posted, cleanup) = makeModel("writable")
    defer { cleanup() }
    let destination = root.appendingPathComponent("WhisperMeet Diagnostics.json")

    model.saveDiagnostics(to: destination)

    #expect(model.alertMessage == nil)
    #expect(posted.bodies.isEmpty)
    let data = try Data(contentsOf: destination)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["meetingCount"] as? Int == 0)
    #expect(object["crashReportCount"] as? Int == 0)
}

@Test("Settings' Export diagnostics… saves through AppModel.saveDiagnostics, not a silent try? write (F513)")
func exportDiagnosticsButtonSavesThroughTheModel() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let button = source.contains("Button(\"Export diagnostics…\") { exportDiagnostics() }")
    #expect(button, "the Settings button no longer calls exportDiagnostics()")
    let start = try #require(source.range(of: "private func exportDiagnostics() {"))
    let body = String(source[start.upperBound...].prefix(400))
    let end = body.range(of: "\n    }").map { String(body[..<$0.lowerBound]) } ?? body
    let savesThroughTheModel = end.contains("model.saveDiagnostics(to: url)")
    let writesSilently = end.contains("try?")
    #expect(savesThroughTheModel, "exportDiagnostics() does not call model.saveDiagnostics(to:):\n\(end)")
    #expect(!writesSilently, "exportDiagnostics() still swallows an error with try?:\n\(end)")
}
