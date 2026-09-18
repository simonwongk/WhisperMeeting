import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F184 — two defects the real run found around the download itself.

@MainActor
private func makeModel() throws -> AppModel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LinkImportCancel-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: "F184b.\(UUID().uuidString)")!
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    model.linkImportEnabled = true
    return model
}

@MainActor
@Test("Stopping while the link is still being looked up is not an error (F184)")
func cancelDuringProbeIsSilent() async throws {
    // The real run showed "The operation couldn't be completed. (Swift.CancellationError error 1.)"
    // as an alert: the download's catch knew a cancel is not a failure, the probe's did not.
    let model = try makeModel()
    model.probeMediaURL = { _ in throw CancellationError() }
    #expect(await model.importFromURL("https://www.youtube.com/watch?v=jNQXAC9IVRw") == nil)
    #expect(model.alertMessage == nil)
}

@Test("Update Downloader updates the runtime this copy of the app actually uses (F184, F312)")
func updaterIsGivenTheLibraryRuntime() {
    // `update-yt-dlp.sh` defaults to the real Application Support runtime. Under WHISPERMEET_LIBRARY
    // the app looks for yt-dlp in the overridden runtime, so an argument-less run updated one
    // install while the app kept using the other.
    let arguments = AppModel.downloaderUpdateArguments(
        script: URL(fileURLWithPath: "/x/update-yt-dlp.sh"),
        environment: ["WHISPERMEET_LIBRARY": "/tmp/scratch-lib"]
    )
    #expect(arguments == ["/x/update-yt-dlp.sh", "/tmp/scratch-lib/Runtime"])
}
