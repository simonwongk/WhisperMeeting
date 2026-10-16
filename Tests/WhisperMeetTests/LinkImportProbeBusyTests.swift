import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F975 — `importFromURL` refused a second start while `isImporting`, but set `isImporting` only after
// `probeMediaURL` had returned, so a Download pressed in a second window's link sheet while the first
// window's import was still looking its link up (yt-dlp's probe, seconds) was not refused: both imports
// ran, two downloads competed for the network, and each landed as its own meeting. The import is busy
// from before its probe, and free again on every way the probe ends short of a download — a failure, a
// Stop, or the long-media confirmation, whose confirmed restart must not be refused.

private struct DownloadRan: Error {}

/// Counts the probes that entered, and holds them until opened (or for ten seconds, so a test against
/// code that lets a second probe in cannot hang).
private final class ProbeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entries = 0
    private var open = false
    var entered: Int { lock.withLock { entries } }
    var isOpen: Bool { lock.withLock { open } }
    func enter() { lock.withLock { entries += 1 } }
    func openUp() { lock.withLock { open = true } }

    func wait() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while !isOpen, ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(20))
        }
        try Task.checkCancellation()
    }
}

/// Polls `condition` until it holds or 30 s pass; the caller `#require`s the result.
private func eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(30)
    while !condition() {
        guard Date() < deadline else { return false }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return true
}

private func makeRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F975-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@MainActor
private func makeModel(root: URL, probe: @escaping @Sendable (String) async throws -> MediaProbe) -> AppModel {
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: testSuiteName())!
    )
    model.linkImportEnabled = true
    model.probeMediaURL = probe
    // A download that runs is the failure these tests are about: it ends the import at once and says so,
    // in words that are not the busy refusal.
    model.downloadMedia = { _, _, _ in throw DownloadRan() }
    model.downloadCaptions = { _, _, _ in [] }
    return model
}

private func gatedProbe(_ gate: ProbeGate, duration: TimeInterval = 600) -> @Sendable (String) async throws -> MediaProbe {
    { _ in
        gate.enter()
        try await gate.wait()
        return MediaProbe(title: "Quarterly review", durationSeconds: duration, uploader: "Acme", language: "en")
    }
}

@MainActor
@Test("A Download pressed in another window while the first import's link is still being looked up is refused as busy (F975)")
func aSecondStartDuringTheProbeIsRefused() async throws {
    let root = try makeRoot("second")
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = ProbeGate()
    let model = makeModel(root: root, probe: gatedProbe(gate))

    let first = model.startLinkImport("https://www.youtube.com/watch?v=abc123")
    try #require(await eventually { gate.entered == 1 }, "the first import's probe never started")
    #expect(model.isImporting, "the import is not busy while its link is looked up")

    // Another window's sheet presses Download while the first import is still probing.
    let second = model.startLinkImport("https://www.youtube.com/watch?v=other")
    let outcome = await second.value
    #expect(outcome == .refused(AppModel.linkImportBusy), "a second import ran beside the first: \(outcome)")
    #expect(gate.entered == 1, "the second start looked its link up too")

    gate.openUp()
    let firstOutcome = await first.value
    #expect(firstOutcome != .refused(AppModel.linkImportBusy), "the first import refused itself: \(firstOutcome)")
    #expect(!model.isImporting, "still busy after the import ended")
}

@MainActor
@Test("The import is free again after a probe that fails, one that is stopped, and one that waits for the long-media confirmation (F975)")
func theImportIsFreeAgainWhenTheProbeDoesNotLeadToADownload() async throws {
    // The probe fails.
    do {
        let root = try makeRoot("fails")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root: root, probe: { _ in throw MediaDownloadError.liveInProgress })
        let outcome = await model.importFromURL("https://www.youtube.com/watch?v=abc123")
        #expect(outcome == .refused(MediaDownloadError.liveInProgress.localizedDescription), "\(outcome)")
        #expect(!model.isImporting, "busy after a failed probe")
    }
    // The probe is stopped (the sheet's Stop, or Escape).
    do {
        let root = try makeRoot("stopped")
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ProbeGate()
        let model = makeModel(root: root, probe: gatedProbe(gate))
        let task = model.startLinkImport("https://www.youtube.com/watch?v=abc123")
        try #require(await eventually { gate.entered == 1 }, "the probe never started")
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(!model.isImporting, "busy after a stopped probe")
    }
    // The probe finds long media: the import waits for the user, and the confirmed restart is not refused.
    do {
        let root = try makeRoot("long")
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ProbeGate()
        gate.openUp()
        let model = makeModel(root: root, probe: gatedProbe(gate, duration: AppModel.longMediaDurationThreshold + 60))
        let asked = await model.importFromURL("https://www.youtube.com/watch?v=abc123")
        #expect(asked == .needsConfirmation, "\(asked)")
        #expect(!model.isImporting, "busy while the long-media confirmation is up")
        let confirmed = await model.importFromURL("https://www.youtube.com/watch?v=abc123", confirmedLongDuration: true)
        #expect(confirmed != .refused(AppModel.linkImportBusy), "the confirmed restart was refused as busy")
        #expect(!model.isImporting)
    }
}

// F612 (1) — a restore confirmed while a link import is still looking its link up is refused, because
// the import is busy from before its probe (F975 made it so; this pins the restore's side of it).
@MainActor
@Test("A restore is not offered while a link import is still looking its link up (F612)")
func aRestoreDuringTheProbeIsRefused() async throws {
    let root = try makeRoot("restore")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = root.appendingPathComponent("Library", isDirectory: true)
    let destination = root.appendingPathComponent("Dest", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let gate = ProbeGate()
    let model = makeModel(root: library, probe: gatedProbe(gate))
    model.store.upsert(MeetingRecord(id: UUID(), title: "Before the backup", status: .recorded))
    let summary = try BackupCoordinator.backUp(source: library, destination: destination, now: 1, retain: 3)
    let generation = destination
        .appendingPathComponent(BackupCoordinator.managedSubfolder, isDirectory: true)
        .appendingPathComponent(summary.generation, isDirectory: true)

    let importing = model.startLinkImport("https://www.youtube.com/watch?v=abc123")
    try #require(await eventually { gate.entered == 1 }, "the import's probe never started")

    await model.requestLibraryRestore(from: generation)

    #expect(model.pendingLibraryRestore == nil, "a restore was offered while a link was being looked up")
    #expect(model.alertMessage?.contains("importing") == true, "\(model.alertMessage ?? "nothing was said")")
    gate.openUp()
    _ = await importing.value
}
