import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F528 — the 1 Hz health tick sent "Recording needs attention: …" only through
// `postWindowlessAlert`, which returns early whenever any readable window exists, on the premise
// that the window's `.alert` shows it. It never did: the announcement was never put on
// `alertMessage`, and the only in-window sign was the health panel, which exists on the New Meeting
// pane alone. So with a window open the warning reached nobody when the user
//   (a) had Zoom in front of the WhisperMeet window on the same Space, or
//   (b) was reading a meeting's notes or Settings in the WhisperMeet window.
//
// Driven through `announceRecordingRisk(from:)` — the call the tick makes — with the window
// situation and the notification post both injected, so "posted" is observed rather than inferred.

@MainActor
private func makeModel(_ label: String) throws -> (AppModel, URL, posts: Locked<[String]>) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F528-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(
            stoppingCapture: {}, finishingTracks: {}, preservingPartialTracks: {},
            startingCapture: { _, _, _ in }, directory: root
        ),
        defaults: UserDefaults(suiteName: "F528.\(label).\(UUID().uuidString)")!,
        whisperExecutable: { nil }, qwenInstalled: { false }
    )
    let posts = Locked<[String]>([])
    model.deliverUserNotification = { _, body in posts.withLock { $0.append(body) } }
    return (model, root, posts)
}

private func snapshot(_ warnings: [RecordingHealthWarning]) -> RecordingHealthSnapshot {
    RecordingHealthSnapshot(
        microphoneLevel: RecordingAudioLevel(rms: 0, peak: 0),
        systemAudioLevel: RecordingAudioLevel(rms: 0, peak: 0),
        availableStorageBytes: nil, warnings: warnings
    )
}

@MainActor
@Test("An at-risk warning reaches a user whose WhisperMeet window is behind another app, once (F528)")
func atRiskReachesAUserBehindAnotherApp() throws {
    let (model, root, posts) = try makeModel("behind")
    defer { try? FileManager.default.removeItem(at: root) }
    // Case (a): a call app in front of a readable WhisperMeet window on the same Space.
    model.windowPresence = { .behindOtherApps }
    model.setRecordingStateForTesting(.recording(startedAt: Date()))
    let dying = snapshot([.microphoneCaptureStopped])
    model.setRecordingHealthForTesting(dying)

    model.announceRecordingRisk(from: dying)
    model.announceRecordingRisk(from: dying)   // the next tick, same problem

    #expect(posts.withLock { $0 }.count == 1, "the user in Zoom was told nothing, or told every second")
    #expect(posts.withLock { $0 }.first?.contains("Microphone capture stopped") == true)
    #expect(model.alertMessage == nil,
            "not on the window's alert as well: that would be the same news twice once they switch back")
}

@MainActor
@Test("With a WhisperMeet window in front, the warning is a banner on every pane, not a notification (F528)")
func atRiskWithTheWindowInFrontIsABannerNotAPost() throws {
    let (model, root, posts) = try makeModel("front")
    defer { try? FileManager.default.removeItem(at: root) }
    // Case (b): the user is in WhisperMeet, reading notes or Settings, away from the health panel.
    model.windowPresence = { .inFront }
    model.setRecordingStateForTesting(.recording(startedAt: Date()))
    let dying = snapshot([.captureWritesFailing])
    model.setRecordingHealthForTesting(dying)

    model.announceRecordingRisk(from: dying)

    #expect(posts.withLock { $0 }.isEmpty, "a notification for a window the user is looking at is noise")
    let line = try #require(model.recordingRiskBannerLine,
                            "nothing in the window said so unless the New Meeting pane was showing")
    #expect(line.contains("Audio is not being saved"))
    #expect(model.alertMessage == nil, "a banner, not a modal alert over the meeting")
}

@MainActor
@Test("The banner is live state: it clears with the problem and when the recording ends, and cautions never show it (F528)")
func theBannerFollowsTheRecordingsHealth() throws {
    let (model, root, _) = try makeModel("live")
    defer { try? FileManager.default.removeItem(at: root) }
    model.setRecordingStateForTesting(.recording(startedAt: Date()))

    model.setRecordingHealthForTesting(snapshot([.microphoneClipping]))
    #expect(model.recordingRiskBannerLine == nil, "a caution degrades a recording; it does not lose it")

    model.setRecordingHealthForTesting(snapshot([.approachingLengthLimit, .lowStorage]))
    #expect(model.recordingRiskBannerLine?.contains("Low storage") == true,
            "the line names the at-risk problem, not a caution ranked beside it")

    model.setRecordingHealthForTesting(snapshot([]))
    #expect(model.recordingRiskBannerLine == nil, "recovered, so the banner goes")

    model.setRecordingHealthForTesting(snapshot([.systemAudioCaptureStopped]))
    model.setRecordingStateForTesting(.stopping)
    #expect(model.recordingRiskBannerLine == nil, "the last snapshot is stale once the recording is finishing (F337)")
}

@MainActor
@Test("With no readable window the warning is still posted, as before (F528)")
func atRiskWithNoWindowIsStillPosted() throws {
    let (model, root, posts) = try makeModel("none")
    defer { try? FileManager.default.removeItem(at: root) }
    model.windowPresence = { .noReadableWindow }
    model.setRecordingStateForTesting(.recording(startedAt: Date()))
    let dying = snapshot([.lowStorage])
    model.setRecordingHealthForTesting(dying)

    model.announceRecordingRisk(from: dying)

    #expect(posts.withLock { $0 }.count == 1)
}

@MainActor
@Test("Other messages keep their rule: posted only with no readable window, since the window's alert shows them (F528)")
func ordinaryMessagesAreNotPostedBehindOtherApps() throws {
    let (model, root, posts) = try makeModel("ordinary")
    defer { try? FileManager.default.removeItem(at: root) }
    model.windowPresence = { .behindOtherApps }
    model.report("The recording could not be finalized automatically.")
    #expect(posts.withLock { $0 }.isEmpty, "a report has an alert in the window; posting too would say it twice")
    #expect(model.alertMessage != nil)
}

@Test("The window hosts the risk banner on its root, beside the other banners, off the New Meeting pane (F528)")
func contentViewHostsTheRiskBanner() throws {
    let content = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let root = try #require(content.range(of: "struct ContentView: View {"))
    let rootEnd = try #require(content.range(of: "private struct MeetingRow: View {"))
    let region = content[root.upperBound..<rootEnd.lowerBound]
    #expect(region.contains("RecordingRiskBanner(model: model, isHealthPanelShowing: showsRecordingHealthPanel)"),
            "the banner must hang off the window's root, which every pane shares")
    #expect(region.contains("ReadOnlyLibraryBanner(model: model)"), "sanity: the overlay the banners share")

    let banner = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/RecordingRiskBanner.swift")
    #expect(banner.contains("model.recordingRiskBannerLine"))
    #expect(banner.contains("!isHealthPanelShowing"), "on the New Meeting pane the health panel already says it")
}

/// A Sendable box, since the seam is a closure.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body(&value)
    }
}
