import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F1006 — since F1001 a stereo recording whose channels cancel when mixed into one is refused only after the whole
// encode and audit, and nothing remembered it: the reason never showed under the Shrink button or in the Storage
// sheet's row, and every press — and every Shrink Selected — encoded the whole recording again, to refuse again.
// Shrink now remembers such a refusal for the session, keyed on the identity of the file it was about, and gives it
// as the reason up front until that file changes.
//
// F799 — Shrink Selected left out every selected meeting still being measured, with no word in the confirmation or
// the summary. It now names each as skipped, with the reason.

private func voice(_ tones: [Double], seconds: Double) -> [Float] {
    var sum = [Float](repeating: 0, count: Int(seconds * 48_000))
    for (index, tone) in tones.enumerated() {
        let rate = 2 + 5 * Double(index) / Double(Swift.max(1, tones.count - 1)), phase = Double(index) * 0.7
        for n in sum.indices {
            let t = Double(n) / 48_000
            sum[n] += Float(0.03 * sin(2 * Double.pi * tone * t) * (0.55 + 0.45 * sin(2 * Double.pi * rate * t + phase)))
        }
    }
    return sum
}

private let seconds: Double = 6
private let voiceA = voice([311, 457, 619, 737, 911, 1_171, 1_409, 1_777, 2_389, 2_917, 3_571, 4_283], seconds: seconds)
private let voiceB = voice([353, 419, 541, 823, 953, 1_291, 1_613, 2_011, 2_557, 2_963, 3_803, 4_621], seconds: seconds)
private let midSide: [[Float]] = [zip(voiceA, voiceB).map { $0 + $1 }, zip(voiceA, voiceB).map { $0 - $1 }]

private final class Count: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

/// A library of meetings, each a two-channel `recording.wav` import of `channels`, with every encode counted.
@MainActor
private struct Library {
    let root: URL
    let model: AppModel
    let encodes = Count()

    init(_ meetings: [(title: String, channels: [[Float]])]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("F1006-\(UUID().uuidString)")
        model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
        for meeting in meetings {
            let id = UUID()
            let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try fixturePolyWAV(meeting.channels).write(to: folder.appendingPathComponent("recording.wav"))
            model.store.upsert(MeetingRecord(id: id, title: meeting.title, duration: seconds,
                                             recordingPath: "Recordings/\(id.uuidString)/recording.wav",
                                             status: .completed, transcriptText: "Hi."))
        }
        model.availableBytesForShrink = { _ in .max }
        let real = model.encodeForShrink, encodes = encodes
        model.encodeForShrink = { encodes.add(); try real($0, $1, $2) }
    }

    func id(_ title: String) throws -> UUID { try #require(model.store.meetings.first { $0.title == title }?.id) }
    func meeting(_ title: String) throws -> MeetingRecord { try #require(model.store.meetings.first { $0.title == title }) }
    func recording(_ title: String) throws -> URL { model.store.recordingURL(for: try meeting(title)) }

    func shrink(_ titles: [String], measure: [String]? = nil) async throws {
        let ids = try titles.map(id)
        await model.refreshStorage(ids: try (measure ?? titles).map(id))
        model.requestShrink(ids: ids)
        await model.performShrink(confirmed: true)?.value
    }
}

@Test("A recording refused because its channels cancel says so up front afterwards, and is not encoded again (F1006)")
@MainActor
func shrinkRemembersACancellationRefusal() async throws {
    let library = try Library([("Client call", midSide)])
    defer { try? FileManager.default.removeItem(at: library.root) }

    try await library.shrink(["Client call"])
    let first = library.model.alertMessage ?? "nil"
    try #require(first.contains("cancel each other"), "fixture: the first press refuses after the encode: \(first)")
    #expect(library.encodes.count == 1)

    // The reason is the meeting's now, under the button and in the Storage sheet's row.
    let reason = library.model.shrinkUnavailability(for: try library.meeting("Client call"))
    guard case let .channelsCancelled(detail)? = reason else {
        Issue.record("not remembered: \(String(describing: reason))"); return
    }
    #expect(detail.hasPrefix("the recording's left and right channels cancel each other at about 0:0"), "\(detail)")
    #expect(reason?.message.contains("won't try again unless that file changes") == true, "\(reason?.message ?? "")")

    // A second press, and a Shrink Selected with an ordinary meeting beside it, encode nothing for it.
    library.model.alertMessage = nil
    try await library.shrink(["Client call"])
    let second = library.model.alertMessage ?? "nil"
    #expect(library.encodes.count == 1, "encoded again only to be refused again: \(second)")
    #expect(second.contains("can't be shrunk now") && second.contains("cancel each other"), "\(second)")
    #expect(FileManager.default.fileExists(atPath: try library.recording("Client call").path))
}

@Test("A remembered refusal ends when the recording changes (F1006)")
@MainActor
func shrinkForgetsARefusalWhenTheRecordingChanges() async throws {
    let library = try Library([("Client call", midSide)])
    defer { try? FileManager.default.removeItem(at: library.root) }
    try await library.shrink(["Client call"])
    try #require(library.model.shrinkUnavailability(for: try library.meeting("Client call")) != nil)

    // The same file rewritten (here with a voice per channel, which shrinks).
    try fixturePolyWAV([voiceA, voiceB]).write(to: try library.recording("Client call"))
    await library.model.refreshStorage(ids: [try library.id("Client call")])
    #expect(library.model.shrinkUnavailability(for: try library.meeting("Client call")) == nil)
    try await library.shrink(["Client call"])
    #expect(library.model.alertMessage?.contains("Shrunk") == true, "\(library.model.alertMessage ?? "nil")")
    #expect(library.encodes.count == 2)
}

@Test("Shrink Selected names a meeting still being measured as skipped, in the confirmation and the summary (F799)")
@MainActor
func shrinkSelectedNamesAMeetingStillBeingMeasured() async throws {
    let library = try Library([("Measured call", [voiceA, voiceB]), ("Unmeasured call", [voiceA, voiceB])])
    defer { try? FileManager.default.removeItem(at: library.root) }
    let ids = [try library.id("Measured call"), try library.id("Unmeasured call")]
    await library.model.refreshStorage(ids: [ids[0]])

    library.model.requestShrink(ids: ids)

    let request = try #require(library.model.pendingShrink)
    #expect(request.titles == ["Measured call"])
    #expect(request.skipped == [.init(title: "Unmeasured call", reason: .stillMeasuring)])
    #expect(AppModel.shrinkConfirmationMessage(request).contains("1 selected meeting(s) can't be shrunk and will be skipped."))
    await library.model.performShrink(confirmed: true)?.value
    let summary = library.model.alertMessage ?? "nil"
    #expect(summary.contains("Shrunk “Measured call”"), "\(summary)")
    #expect(summary.contains("“Unmeasured call” was skipped. Its size is still being measured"), "\(summary)")

    // Every one selected unmeasured: said, not "nothing to shrink".
    let other = try Library([("Unmeasured call", [voiceA, voiceB])])
    defer { try? FileManager.default.removeItem(at: other.root) }
    other.model.requestShrink(ids: [try other.id("Unmeasured call")])
    #expect(other.model.pendingShrink == nil)
    #expect(other.model.alertMessage == "“Unmeasured call” can't be shrunk now. Its size is still being measured; try again in a moment.")
}

// F1008 — measured in a release build, a three-hour stereo recording's whole Shrink takes about 46 s, 30 s of it the
// channel check; meanwhile the meeting's own Shrink button said "Another meeting is being shrunk." about itself.

private final class Gate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
}

@Test("While a meeting is being shrunk, its own reason says so; another meeting's says another is (F1008)")
@MainActor
func shrinkSaysItIsShrinkingThisMeeting() async throws {
    let library = try Library([("Long call", [voiceA, voiceB]), ("Other call", [voiceA, voiceB])])
    defer { try? FileManager.default.removeItem(at: library.root) }
    let gate = Gate()
    defer { gate.release.signal() }  // never leave the encode blocked, whatever fails first
    let real = library.model.encodeForShrink
    library.model.encodeForShrink = { input, output, working in
        gate.entered.signal()
        gate.release.wait()
        try real(input, output, working)
    }
    let ids = [try library.id("Long call"), try library.id("Other call")]
    await library.model.refreshStorage(ids: ids)
    library.model.requestShrink(ids: [ids[0]])
    let work = try #require(library.model.performShrink(confirmed: true))
    try await pollUntil("the encode to start") { library.model.shrinkRunningID == ids[0] }

    let own = library.model.shrinkUnavailability(for: try library.meeting("Long call"))
    let other = library.model.shrinkUnavailability(for: try library.meeting("Other call"))
    gate.release.signal()
    await work.value
    #expect(own == .shrinkingNow, "\(String(describing: own?.message))")
    #expect(own?.message.hasPrefix("Shrinking now.") == true)
    #expect(other == .anotherShrinkRunning)
    #expect(library.model.alertMessage?.contains("Shrunk") == true, "\(library.model.alertMessage ?? "nil")")
}
