import Combine
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F802 — `refreshStorage(ids:)` assigned `storageFacts[id]` once per meeting, so measuring a library
// of 500 published 500 changes to every view observing the model; Settings and the Storage sheet
// both measure the whole library when they appear. And a re-measure that was already under way when
// a Shrink ran published its reading after the Shrink's own final one, so a just-shrunk meeting
// showed its deleted originals and an enabled Shrink… right after "Shrunk".

/// A `storageEntries` seam that holds one chosen call after it has listed the folder, so that
/// call's reading is taken now and published later. The other calls list the folder and return.
private final class HeldListing: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var _entered = false
    private let heldCall: Int
    private let release = DispatchSemaphore(value: 0)

    init(holding heldCall: Int) { self.heldCall = heldCall }

    var entered: Bool { lock.withLock { _entered } }
    func letGo() { release.signal() }

    func list(_ folder: URL) -> [MeetingStoragePlan.FolderEntry] {
        let entries = MeetingStorageMeter.entries(in: folder)
        let call = lock.withLock { () -> Int in calls += 1; return calls }
        guard call == heldCall else { return entries }
        lock.withLock { _entered = true }
        // A bound, not a budget: the test releases it as soon as its Shrink is done. It only keeps a
        // regression from hanging the suite.
        _ = release.wait(timeout: .now() + 60)
        return entries
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws -> Bool {
    let deadline = Date().addingTimeInterval(30)
    while !condition() {
        if Date() > deadline { return false }
        try await Task.sleep(for: .milliseconds(5))
    }
    return true
}

@MainActor
private func makeCapture(seconds: Double = 60) throws -> (root: URL, model: AppModel, id: UUID, folder: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F802-\(UUID().uuidString)")
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // As ShrinkFlowTests' fixture: a real WAV, both raw tracks and a manifest that matches them, so
    // Verify Library and Rebuild Audio find nothing wrong and Shrink proceeds.
    try WAVWriter.wavData(from: [Float](repeating: 0.1, count: Int(seconds * 48_000)), sampleRate: 48_000)
        .write(to: folder.appendingPathComponent("meeting.wav"))
    let trackBytes = 6_000_000
    for name in ["system-audio.f32", "microphone-audio.f32"] {
        try Data(count: trackBytes).write(to: folder.appendingPathComponent(name))
    }
    try Data("""
        {"systemAudio":{"file":"system-audio.f32","frameCount":\(trackBytes / 4)},
         "microphoneAudio":{"file":"microphone-audio.f32","frameCount":\(trackBytes / 4)}}
        """.utf8).write(to: folder.appendingPathComponent("source-tracks.json"))
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    model.store.upsert(MeetingRecord(
        id: id, title: "Weekly sync", duration: seconds,
        recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed, transcriptText: "Hi."))
    model.encodeForShrink = { _, output, _ in try Data(count: 15_000).write(to: output) }
    model.decodeForShrink = { _ in DecodedAudio.Decoded(duration: seconds, level: 0.1) }
    model.declaredDurationForShrink = { _ in seconds }
    model.availableBytesForShrink = { _ in .max }
    model.decodeUnreadableForShrink = { _, output in
        try WAVWriter.wavData(from: [Float](repeating: 0.1, count: 16_000), sampleRate: 16_000).write(to: output)
    }
    return (root, model, id, folder)
}

@Test("A re-measure under way when a Shrink runs does not replace the Shrink's final reading (F802)")
@MainActor
func refreshDuringShrinkKeepsThePostShrinkFacts() async throws {
    let (root, model, id, _) = try makeCapture()
    defer { try? FileManager.default.removeItem(at: root) }
    // Call 1 is the measurement Shrink needs before it can be requested; call 2 is the racing
    // re-measure (the header's `.task(id:)`), held after it has listed the original files.
    let listing = HeldListing(holding: 2)
    model.storageEntries = { listing.list($0) }
    await model.refreshStorage(ids: [id])
    model.requestShrink(ids: [id])
    try #require(model.pendingShrink != nil, "the fixture must be shrinkable: \(model.alertMessage ?? "nil")")

    let refresh = Task { await model.refreshStorage(ids: [id]) }
    try #require(try await waitUntil { listing.entered }, "the re-measure never started")
    await model.performShrink(confirmed: true)?.value
    try #require(model.alertMessage?.contains("Shrunk") == true, "\(model.alertMessage ?? "nil")")
    let afterShrink = model.storageFacts[id]
    listing.letGo()
    await refresh.value

    let names = Set(model.storageFacts[id]?.entries.map(\.name) ?? [])
    #expect(names.contains("meeting.m4a"), "\(names.sorted())")
    #expect(!names.contains("meeting.wav"), "the held reading of the originals was published over Shrink's: \(names.sorted())")
    #expect(model.storageFacts[id] == afterShrink)
}

@Test("An older re-measure that finishes last does not replace a newer one's reading (F802)")
@MainActor
func anOlderRefreshFinishingLastLosesToTheNewer() async throws {
    let (root, model, id, folder) = try makeCapture(seconds: 1)
    defer { try? FileManager.default.removeItem(at: root) }
    let listing = HeldListing(holding: 1)
    model.storageEntries = { listing.list($0) }

    let older = Task { await model.refreshStorage(ids: [id]) }
    try #require(try await waitUntil { listing.entered }, "the first re-measure never started")
    // The folder changes, and a second re-measure (a stop, a rebuild) sees the change and finishes.
    try Data(count: 1_000).write(to: folder.appendingPathComponent("notes.md"))
    await model.refreshStorage(ids: [id])
    try #require(model.storageFacts[id]?.entries.contains { $0.name == "notes.md" } == true)
    listing.letGo()
    await older.value

    #expect(model.storageFacts[id]?.entries.contains { $0.name == "notes.md" } == true,
            "the older reading, taken before notes.md existed, replaced the newer one")
}

@Test("Measuring several meetings publishes once, not once per meeting (F802)")
@MainActor
func refreshPublishesOncePerCall() async throws {
    let (root, model, first, _) = try makeCapture(seconds: 1)
    defer { try? FileManager.default.removeItem(at: root) }
    var ids = [first]
    for index in 0..<3 {
        let id = UUID()
        let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try WAVWriter.wavData(from: [Float](repeating: 0.1, count: 16_000), sampleRate: 16_000)
            .write(to: folder.appendingPathComponent("meeting.wav"))
        model.store.upsert(MeetingRecord(
            id: id, title: "Meeting \(index)", duration: 1,
            recordingPath: "Recordings/\(id.uuidString)/meeting.wav", status: .completed))
        ids.append(id)
    }
    var publishes = 0
    let observer = model.$storageFacts.dropFirst().sink { _ in publishes += 1 }
    defer { observer.cancel() }

    await model.refreshStorage(ids: ids)

    #expect(Set(model.storageFacts.keys) == Set(ids))
    #expect(publishes == 1)
}
