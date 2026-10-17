import Foundation
import Testing
@testable import WhisperCore

// F753 — `RecordingSession.capturedAlignment`, an append-only optional field, with F188's fixtures in
// both directions: a session written before the field decodes in this build, and a session this build
// writes decodes in the previous one (its decoder replicated below, field for field).

private let sessionBeforeF753 = #"""
{"id":"9E1C7A44-0000-4000-8000-000000000001","startedAt":"2026-10-01T09:00:00Z","title":"Board call",
 "markers":[{"id":"9E1C7A44-0000-4000-8000-0000000000AA","offset":12.5,"label":"Decision"}],
 "paddedGaps":[{"seconds":4,"resumedAt":"2026-10-01T09:10:00Z"}]}
"""#

private func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}

/// The previous build's `RecordingSession` decoder, as it was before F753: every field it knew, read
/// exactly as it read them. JSONDecoder ignores keys a type does not name.
private struct PreviousRecordingSession: Decodable {
    struct Gap: Decodable { let seconds: TimeInterval; let resumedAt: Date }
    let id: UUID
    let startedAt: Date
    let title: String
    let markers: [RecordingMarker]
    let interruptedBySleepAt: Date?
    let paddedGaps: [Gap]
    let outageBeganAt: Date?
    enum CodingKeys: String, CodingKey { case id, startedAt, title, markers, interruptedBySleepAt, paddedGaps, outageBeganAt }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        markers = try container.decodeIfPresent([RecordingMarker].self, forKey: .markers) ?? []
        interruptedBySleepAt = try container.decodeIfPresent(Date.self, forKey: .interruptedBySleepAt)
        paddedGaps = try container.decodeIfPresent([Gap].self, forKey: .paddedGaps) ?? []
        outageBeganAt = try container.decodeIfPresent(Date.self, forKey: .outageBeganAt)
    }
}

@Test("A session written before F753 decodes with no captured alignment and keeps its markers (F753, F188)")
func aSessionFromBeforeF753Decodes() throws {
    let session = try decoder().decode(RecordingSession.self, from: Data(sessionBeforeF753.utf8))
    #expect(session.capturedAlignment == nil)
    #expect(session.title == "Board call")
    #expect(session.markers.count == 1)
    #expect(session.paddedGaps.count == 1)
}

@Test("A session this build writes decodes in the previous build, which ignores the new field (F753, F188)")
func aSessionWithCapturedAlignmentDecodesInThePreviousBuild() throws {
    var session = try decoder().decode(RecordingSession.self, from: Data(sessionBeforeF753.utf8))
    session.capturedAlignment = RecordingSession.CapturedAlignment(
        systemStartOffsetSeconds: 0, microphoneStartOffsetSeconds: 0.2,
        systemDroppedFrames: 0, microphoneDroppedFrames: 960,
        paddedGaps: [SourceTrackManifest.PaddedGap(startSeconds: 30, durationSeconds: 4)]
    )
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("F753-session-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try RecordingSessionSidecar.write(session, in: directory)
    let written = try Data(contentsOf: directory.appendingPathComponent(RecordingSessionSidecar.filename))

    let object = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
    #expect(object["capturedAlignment"] != nil, "the field never reached the file")
    let previous = try decoder().decode(PreviousRecordingSession.self, from: written)
    #expect(previous.title == "Board call")
    #expect(previous.markers.count == 1)
    #expect(previous.paddedGaps.count == 1)
    // And this build reads it back whole.
    #expect(RecordingSessionSidecar.read(in: directory) == session)
}

@Test("A captured alignment this build cannot read costs only that field, never the markers (F753)")
func anUnreadableCapturedAlignmentCostsOnlyItself() throws {
    var object = try #require(try JSONSerialization.jsonObject(with: Data(sessionBeforeF753.utf8)) as? [String: Any])
    object["capturedAlignment"] = ["systemStartOffsetSeconds": "not a number"]
    let session = try decoder().decode(RecordingSession.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(session.capturedAlignment == nil)
    #expect(session.markers.count == 1)
}

@Test("The session's alignment is derived by the manifest's own rule (F753)")
func capturedAlignmentUsesTheManifestsRule() throws {
    let system = FloatTrack(url: URL(fileURLWithPath: "/tmp/system-audio.f32"), firstPresentationTime: 100.0, frameCount: 96_000)
    let microphone = FloatTrack(url: URL(fileURLWithPath: "/tmp/microphone-audio.f32"), firstPresentationTime: 100.2, frameCount: 86_400)
    let alignment = try #require(SourceTrackManifest.capturedAlignment(system: system, microphone: microphone))
    #expect(alignment.systemStartOffsetSeconds == 0)
    #expect(abs(alignment.microphoneStartOffsetSeconds - 0.2) < 0.000_001)
    // A track that never received a buffer starts with the other, as `write` places it.
    let silent = FloatTrack(url: microphone.url, firstPresentationTime: nil, frameCount: 0)
    #expect(SourceTrackManifest.capturedAlignment(system: system, microphone: silent)?.microphoneStartOffsetSeconds == 0)
    let neither = FloatTrack(url: system.url, firstPresentationTime: nil, frameCount: 0)
    #expect(SourceTrackManifest.capturedAlignment(system: neither, microphone: silent) == nil)
}
