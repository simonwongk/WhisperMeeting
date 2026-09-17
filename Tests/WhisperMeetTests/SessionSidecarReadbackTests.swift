import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F274 — F258 wrote the session sidecar and nothing read it back.
//
// A `session.json` is written when recording starts and rewritten on every marker drop, so marker
// offsets survive a crash, ⌘Q or a shutdown. The orphan-recovery upsert then constructed its
// `MeetingRecord` with no markers at all, so a meeting recovered on the next launch came back with
// zero markers while the offsets sat on disk beside it. The same is true of
// `interruptedBySleepAt`: F253 records WHY a capture stopped and nothing ever said so.
//
// The ticket also lists a health report. There is no such field on `RecordingSession` — checked
// rather than assumed — so nothing writes one and there is nothing to read back. The title half is
// deferred to F257's lifecycle work for the reason the ticket gives: it is view-local `@State`, so
// there is nothing to persist at start yet.

@MainActor
private func makeModel(root: URL, suite: String) -> AppModel {
    AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: suite)!
    )
}

/// An interrupted capture folder with a sidecar, as F258 leaves it.
private func makeInterruptedFolder(
    in root: URL,
    markers: [RecordingMarker],
    sleptAt: Date? = nil
) throws -> UUID {
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let samples = [Float](repeating: 0.25, count: 96_000)
    try samples.withUnsafeBytes {
        try Data($0).write(to: folder.appendingPathComponent("system-audio.f32"))
    }
    var session = RecordingSession(
        id: id, startedAt: Date().addingTimeInterval(-300), title: "", markers: markers
    )
    session.interruptedBySleepAt = sleptAt
    try RecordingSessionSidecar.write(session, in: folder)
    return id
}

@Test("A recovered meeting comes back with the markers the sidecar preserved")
@MainActor
func recoveredMeetingCarriesItsMarkers() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SidecarReadback-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = try makeInterruptedFolder(in: root, markers: [
        RecordingMarker(offset: 12.5, label: "pricing"),
        RecordingMarker(offset: 90, label: nil),
    ])

    let suite = "WhisperMeet.SidecarReadback.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let model = makeModel(root: root, suite: suite)
    await model.performStartupRecovery()

    let meeting = try #require(model.store.meeting(id: id))
    // The whole point of F258's write half, finally reachable.
    #expect(meeting.orderedMarkers.count == 2)
    #expect(meeting.orderedMarkers.first?.label == "pricing")
    #expect(meeting.orderedMarkers.first?.offset == 12.5)
}

@Test("A recovery with no markers stores nil rather than an empty list")
@MainActor
func noMarkersMeansNil() async throws {
    // The existing convention, and it is not cosmetic: `markers` is an optional so an index
    // written before the feature decodes, and writing `[]` everywhere would make the absent case
    // indistinguishable from the empty one.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SidecarNoMarkers-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = try makeInterruptedFolder(in: root, markers: [])

    let suite = "WhisperMeet.SidecarNoMarkers.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let model = makeModel(root: root, suite: suite)
    await model.performStartupRecovery()

    #expect(try #require(model.store.meeting(id: id)).markers == nil)
}

@Test("A recovery says the Mac went to sleep, when that is why it stopped")
@MainActor
func sleepInterruptionIsExplained() async throws {
    // F253 records WHY the capture stopped and nothing ever said so. "Recovered after an
    // interruption" is true and unhelpful; the user knows they closed the lid and wants the app to
    // know it too. No new field: the existing recovery message says which interruption it was.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SidecarSleep-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = try makeInterruptedFolder(in: root, markers: [], sleptAt: Date().addingTimeInterval(-60))

    let suite = "WhisperMeet.SidecarSleep.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let model = makeModel(root: root, suite: suite)
    await model.performStartupRecovery()

    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.errorMessage?.contains("went to sleep") == true)
}

@Test("A recovery with no sidecar at all still works, and claims no cause")
@MainActor
func missingSidecarIsNotAFailure() async throws {
    // A folder from before F258, or one whose sidecar write failed — which is best-effort by
    // design. Recovery must not depend on metadata it might not have, and must not invent a cause.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SidecarAbsent-\(UUID().uuidString)", isDirectory: true)
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let samples = [Float](repeating: 0.25, count: 96_000)
    try samples.withUnsafeBytes {
        try Data($0).write(to: folder.appendingPathComponent("system-audio.f32"))
    }

    let suite = "WhisperMeet.SidecarAbsent.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let model = makeModel(root: root, suite: suite)
    await model.performStartupRecovery()

    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.markers == nil)
    #expect(meeting.errorMessage?.contains("went to sleep") != true)
    #expect(meeting.errorMessage?.contains("Recovered from source audio") == true)
}
