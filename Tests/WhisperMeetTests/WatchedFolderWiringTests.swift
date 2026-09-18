import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F318 — the AppModel side of the watched folder: off by default, nothing before startup recovery,
// and a finished file that arrives while the app is busy waits instead of being lost.

@MainActor
private func makeModel() throws -> (AppModel, UserDefaults) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("WatchedFolder-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: "F318.\(UUID().uuidString)")!
    return (AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults), defaults)
}

@MainActor
@Test("The watched folder is off until the user turns it on and picks a folder (F318)")
func watchedFolderIsOptIn() throws {
    let (model, _) = try makeModel()
    #expect(!model.watchedFolderEnabled)
    #expect(model.watchedFolderPath == nil)
}

@MainActor
@Test("A finished file that arrives during a recording waits, and is imported afterwards (F318)")
func busyAppKeepsTheFileForLater() async throws {
    let (model, defaults) = try makeModel()
    let file = URL(fileURLWithPath: "/inbox/call.m4a")
    model.setRecordingStateForTesting(.recording(startedAt: Date()))
    model.watchedFolderLooked(at: Date(), ready: [file])
    #expect(model.pendingWatchedFiles == [file], "handed over once by the inbox, so it must not be dropped")
    #expect(defaults.object(forKey: AppModel.watchedFolderLastLookKey) == nil,
            "quitting now must leave the waiting file new for the next launch")
    _ = defaults

    model.setRecordingStateForTesting(.idle)
    model.watchedFolderLooked(at: Date(), ready: [])
    #expect(model.pendingWatchedFiles.isEmpty, "taken for import on the first free look")
}

@MainActor
@Test("The last look survives a relaunch, and belongs only to the folder it was written for (F318)")
func lastLookSurvivesARelaunch() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("WatchedFolderRelaunch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "F318.relaunch.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let first = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    first.watchedFolderPath = "/inbox"
    let looked = Date(timeIntervalSince1970: 1_000)
    first.watchedFolderLooked(at: looked, ready: [])

    // A second launch loads the saved path in `init` — which is exactly what used to wipe the date.
    _ = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    #expect(AppModel.watchedFolderLastLook(for: "/inbox", in: defaults) == looked)
    #expect(AppModel.watchedFolderLastLook(for: "/somewhere/else", in: defaults) == nil)
}

@Test("Settings offers the folder and startup recovery starts the watcher (F318)")
func watchedFolderIsReachable() throws {
    func source(_ path: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path), encoding: .utf8)
    }
    let view = try source("Sources/WhisperMeet/ContentView.swift")
    #expect(view.contains("isOn: $model.watchedFolderEnabled"))
    #expect(view.contains("model.watchedFolderPath = url.path"))
    let model = try source("Sources/WhisperMeet/AppModel.swift")
    #expect(model.contains("defer { restartWatchedFolder() }"))
}
