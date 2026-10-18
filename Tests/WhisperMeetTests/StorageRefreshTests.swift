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

// MARK: - Round 2 (the review of lane U, findings 1 and 5)

/// A `storageEntries` seam that holds chosen calls per folder, after listing it.
private final class FolderGate: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String: Int] = [:]
    private var holds: [String: DispatchSemaphore] = [:]
    private var entered: Set<String> = []

    func hold(_ folder: String, call: Int) {
        lock.withLock { holds["\(folder)#\(call)"] = DispatchSemaphore(value: 0) }
    }
    func hasEntered(_ folder: String, call: Int) -> Bool { lock.withLock { entered.contains("\(folder)#\(call)") } }
    func release(_ folder: String, call: Int) { lock.withLock { holds["\(folder)#\(call)"] }?.signal() }
    func callCount(_ folder: String) -> Int { lock.withLock { calls[folder, default: 0] } }

    func list(_ url: URL) -> [MeetingStoragePlan.FolderEntry] {
        let entries = MeetingStorageMeter.entries(in: url)
        let name = url.lastPathComponent
        let (key, gate) = lock.withLock { () -> (String, DispatchSemaphore?) in
            calls[name, default: 0] += 1
            let key = "\(name)#\(calls[name]!)"
            return (key, holds[key])
        }
        guard let gate else { return entries }
        lock.withLock { _ = entered.insert(key) }
        // A bound, not a budget: each test releases its holds. It only keeps a regression from hanging.
        _ = gate.wait(timeout: .now() + 60)
        return entries
    }
}

@MainActor
private func addMeeting(_ model: AppModel, root: URL, title: String) throws -> (UUID, URL) {
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try WAVWriter.wavData(from: [Float](repeating: 0.1, count: 16_000), sampleRate: 16_000)
        .write(to: folder.appendingPathComponent("meeting.wav"))
    model.store.upsert(MeetingRecord(id: id, title: title, duration: 1,
                                     recordingPath: "Recordings/\(id.uuidString)/meeting.wav", status: .completed))
    return (id, folder)
}

// The review's probe R1: a refresh numbered when it STARTED let a page re-measure that started later,
// but measured B earlier, replace the library refresh's newer reading of B. Each meeting's reading is
// now numbered when it is taken.
@Test("A re-measure that started later but measured earlier does not replace a newer reading (F802, round 2)")
@MainActor
func aLaterStartedRefreshHoldingAnOlderReadingLoses() async throws {
    let (root, model, _, _) = try makeCapture(seconds: 1)
    defer { try? FileManager.default.removeItem(at: root) }
    let (a, folderA) = try addMeeting(model, root: root, title: "A")
    let (b, folderB) = try addMeeting(model, root: root, title: "B")
    let gate = FolderGate()
    model.storageEntries = { gate.list($0) }
    await model.refreshStorage(ids: [b])                              // B call 1

    gate.hold(folderA.lastPathComponent, call: 1)
    gate.hold(folderB.lastPathComponent, call: 2)
    // The Settings row / Storage sheet measuring the library, held on A before it reaches B.
    let library = Task { await model.refreshStorage(ids: [a, b]) }
    try #require(try await waitUntil { gate.hasEntered(folderA.lastPathComponent, call: 1) })
    // The meeting page's re-measure of B, which lists B now and is held after listing.
    let page = Task { await model.refreshStorage(ids: [b]) }
    try #require(try await waitUntil { gate.hasEntered(folderB.lastPathComponent, call: 2) })
    // B changes; the library refresh then measures B (call 3) and sees it.
    try Data(count: 1_000).write(to: folderB.appendingPathComponent("notes.md"))
    gate.release(folderA.lastPathComponent, call: 1)
    await library.value
    try #require(model.storageFacts[b]?.entries.contains { $0.name == "notes.md" } == true,
                 "precondition: the library refresh's newer reading was published")
    gate.release(folderB.lastPathComponent, call: 2)
    await page.value

    #expect(model.storageFacts[b]?.entries.contains { $0.name == "notes.md" } == true,
            "the page refresh's reading, taken before notes.md existed, replaced the newer one")
}

// The review's finding 5: nothing pinned the skip. It is defence in depth — the change rule already
// drops a reading that a Shrink's own writes overtook — and keeps a reading of a folder mid-Shrink
// (the new file half-written, the originals not yet removed) from being taken or published at all.
@Test("A meeting being shrunk is not measured, and its facts are left to the Shrink (F802, round 2)")
@MainActor
func aMeetingBeingShrunkIsNotMeasured() async throws {
    let (root, model, _, _) = try makeCapture(seconds: 1)
    defer { try? FileManager.default.removeItem(at: root) }
    let (a, folderA) = try addMeeting(model, root: root, title: "A")
    let (b, folderB) = try addMeeting(model, root: root, title: "B")
    let gate = FolderGate()
    model.storageEntries = { gate.list($0) }
    await model.refreshStorage(ids: [a, b])
    let factsBefore = try #require(model.storageFacts[a])
    try Data(count: 1_000).write(to: folderA.appendingPathComponent("notes.md"))

    model.shrinkRunningID = a
    await model.refreshStorage(ids: [a, b])
    model.shrinkRunningID = nil

    #expect(gate.callCount(folderA.lastPathComponent) == 1, "the meeting being shrunk was measured")
    #expect(gate.callCount(folderB.lastPathComponent) == 2, "the other meeting is measured as usual")
    #expect(model.storageFacts[a] == factsBefore, "a reading of a folder mid-Shrink was published")
}
