import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F304 — `MeetingRecord` has a hand-written `CodingKeys` (F250 added it to remap
// `transcriptionEngineRawValue`), and a hand-written one means Swift encodes **only** the listed
// keys. Two fields were not listed, so they were in-memory only:
//
//   - `recoverySource`, which is the entirety of F273's fix. That ticket exists because provenance
//     lived in a field another path cleared; the fix moved it into a field nothing persisted. The
//     provenance survived transcription and did not survive a reload, which is the same
//     user-visible outcome through a different door.
//   - `staleTranscriptWarning`, F267's notice that a rebuilt recording's old transcript is stale.
//
// Two tickets forgot the same step, so the guard here is structural rather than two more
// assertions: every STORED property must appear in the wire format. `Mirror` sees stored properties
// and not computed ones, which is exactly the distinction that matters — `transcriptionEngine` is
// computed over `transcriptionEngineRawValue` and correctly absent.

/// Every field populated, because `JSONEncoder` omits a nil optional and a nil field would look
/// identical to a missing key. Anything added to `MeetingRecord` has to be added there too, and the
/// test below is what says so.
///
/// It said so within the hour. F305 added `recoveryInterruption` and this file's fixture did not set
/// it; the test named the field — *"these stored fields never reach disk: recoveryInterruption"* —
/// while `theWireKeySetIsPinned`, whose fixture also did not set it, passed. That is the whole
/// difference between deriving the list and restating it, demonstrated on a field added after both
/// were written.
///
/// One builder, shared with F382's derived decode test (F777, from F776). This file kept a second,
/// hand-kept copy while F552 was editing it, and only the shared one is checked complete at every
/// nested level — this copy had already drifted: its summary had no owners or quotes and its health
/// report none of F346's frame counts.
private func fullyPopulatedRecord() -> MeetingRecord {
    PersistedRootDerivedDecodeTests.fullyPopulatedMeeting()
}

@Test("Every stored field of a MeetingRecord, at every depth, reaches the wire format and comes back (F304, F777)")
func everyStoredFieldIsEncoded() throws {
    // The guard that makes the class impossible. A field absent from `CodingKeys` is dropped on the
    // next save with no error anywhere — the index still parses, the app still runs, and the fact is
    // simply gone. It reflected `MeetingRecord`'s own top level only (F777, from F773), so a field
    // dropped by a nested type's `CodingKeys` — an action item's, a health report's — passed; it now
    // walks the record through F544's recursive helper, and checks the decode side too.
    let record = fullyPopulatedRecord()

    // `Mirror` reports stored properties only, which is the right set: a computed property has
    // nothing to persist. `transcriptionEngine` is computed over the raw value and must NOT appear.
    let stored = Mirror(reflecting: record).children.compactMap(\.label)
    #expect(!stored.isEmpty, "Mirror found no properties, so this test would pass vacuously")
    #expect(!stored.contains("transcriptionEngine"), "a computed property should not be reflected")

    // The documented remaps: the property is `transcriptionEngineRawValue`, the key is
    // `transcriptionEngine` (F250); the property is `schemaMarker`, the key is `schemaVersion`
    // (F552). For these two the property name is not the key name.
    let coverage = try storedPropertiesMissingFromWire(
        record,
        remapped: ["transcriptionEngineRawValue": "transcriptionEngine", "schemaMarker": "schemaVersion"]
    )
    #expect(coverage.usedRemaps == ["transcriptionEngineRawValue", "schemaMarker"], "a remap names no stored property")
    // Anti-vacuity: the walk reached the nested paths it exists for.
    let mustCheck = [
        "summary.actionItems[0].owner", "summary.actionItems[0].quote", "healthReport.microphoneWorstSecond.framesMeasured",
        "healthReport.systemAudioFramesAtFullScale", "source.videoID", "segments[0].avgLogprob", "markers[0].label",
        "referenceSegments[0].text", "schemaMarker", "transcriptionEngineRawValue",
    ]
    let unvisited = mustCheck.filter { !coverage.checked.contains($0) }
    #expect(unvisited.isEmpty, "the walk never reached \(unvisited.joined(separator: ", "))")
    #expect(
        coverage.missing.isEmpty,
        "these stored fields never reach disk, so they are lost on the next save: \(coverage.missing.sorted().joined(separator: ", "))"
    )
    let lost = try storedPropertiesLostOnReload(record)
    #expect(
        lost.isEmpty,
        "these stored fields reach disk and do not come back on load, so the next save drops them: \(lost.sorted().joined(separator: ", "))"
    )
}

@Test("A record's recovery provenance and stale notice survive a save and reload (F304, F273, F267)")
func provenanceSurvivesARoundTrip() throws {
    // The instance, stated separately from the class above, because this is the one with a user
    // consequence: F273's whole subject is that this fact must outlive the things that happen to a
    // meeting, and a reload is the most ordinary of them.
    let record = fullyPopulatedRecord()
    let restored = try JSONDecoder().decode(
        MeetingRecord.self, from: try JSONEncoder().encode(record)
    )

    #expect(restored.recoverySource == RecoveredRecording.Source.rebuiltSourceTracks.rawValue)
    #expect(restored.staleTranscriptWarning == "stale")
    #expect(restored.summaryLanguageWarning == "summary language")
    let caveats = MeetingStore.recoveryCaveats(for: restored)
    #expect(caveats.contains { $0.contains("rebuilt from its raw microphone") })
    #expect(caveats.contains("stale"))
}

@Test("An index written before these fields existed still decodes (F304)")
func olderIndexStillDecodes() throws {
    // The other half of the leniency rule (F250/F187): adding keys must not make an older index
    // unreadable. An absent key is nil, not a failure.
    let json = """
    {"id":"\(UUID().uuidString)","title":"old","createdAt":700000000,"duration":0,
     "recordingPath":"","status":"completed","transcriptText":"","segments":[]}
    """
    let restored = try JSONDecoder().decode(
        MeetingRecord.self, from: Data(json.utf8)
    )
    #expect(restored.recoverySource == nil)
    #expect(restored.staleTranscriptWarning == nil)
    #expect(restored.summaryLanguageWarning == nil)
    #expect(MeetingStore.recoveryCaveats(for: restored).isEmpty)
}
