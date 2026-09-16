import Foundation
import Testing
@testable import WhisperCore

// F188 — a raw value an older build has never heard of must not brick the library.
//
// This is the mechanism behind the 2026-08-14 index wipe, recorded in
// docs/LIBRARY_INDEX_WIPE_POSTMORTEM_2026-08-14.md: a newer bundle writes `meetings.json`, an older
// bundle opens it, one `Codable` decode throws `dataCorrupted`, and the whole index reads as
// unreadable. F187 turned that from a wipe into a read-only library, and F190 made the previous
// generations restorable — but neither stops the decode from failing in the first place.
//
// The postmortem named exactly three undefended types in the persisted meeting graph:
// `RecordingHealthStatus`, `RecordingHealthWarning` and `MeetingTranscriptionEngine` all throw on an
// unknown raw value, while `MeetingStatus` alone decodes leniently (MeetingStore.swift:10-19).
// These tests hold each of the three to the `MeetingStatus` precedent: map to a documented safe
// value, never throw.
//
// Each mapping below is deliberately LOSSY and that is a policy choice, not an oversight. F188 asks
// for "round-trip losslessly or force a no-write compatibility state"; a third option — decode to a
// safe value and keep writing — is chosen here because the alternative is making a whole library
// read-only over one unrecognised health warning, which is worse than the failure it prevents. The
// cost is that re-saving an index read by an older build drops the unknown value permanently.

private let decoder = JSONDecoder()

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try decoder.decode(type, from: Data(json.utf8))
}

@Suite("F188 persisted schema compatibility")
struct PersistedSchemaCompatibilityTests {

    // MARK: RecordingHealthStatus

    @Test("An unknown recording-health status decodes to caution rather than throwing")
    func unknownHealthStatusIsCaution() throws {
        let decoded = try decode(RecordingHealthStatus.self, "\"someFutureRisk\"")
        // `.caution` is the honest middle: its own documentation is "worth a glance but the
        // recording is not in danger", which is exactly what an unrecognised status means. Mapping
        // to `.good` would hide a real new risk; mapping to `.atRisk` would raise a scary banner for
        // something that may be benign.
        #expect(decoded == .caution)
    }

    @Test("Known recording-health statuses still decode exactly")
    func knownHealthStatusesRoundTrip() throws {
        #expect(try decode(RecordingHealthStatus.self, "\"good\"") == .good)
        #expect(try decode(RecordingHealthStatus.self, "\"caution\"") == .caution)
        #expect(try decode(RecordingHealthStatus.self, "\"atRisk\"") == .atRisk)
    }

    // MARK: RecordingHealthWarning

    @Test("An unknown warning is dropped from a health report, keeping the known ones")
    func unknownHealthWarningIsDropped() throws {
        let json = """
        {
          "warnings": ["lowStorage", "someFutureWarning", "microphoneClipping"],
          "worstStatus": "caution",
          "microphoneStaleSeconds": 0,
          "systemAudioStaleSeconds": 0,
          "systemAudioEverDetected": true
        }
        """
        let report = try decode(RecordingHealthReport.self, json)
        // Dropped rather than preserved: a warning this build cannot name has no title to render and
        // no explanation to offer, so keeping a placeholder would put an unlabelled row in the health
        // sheet. `worstStatus` still carries the severity the newer build assigned.
        #expect(report.warnings == [.lowStorage, .microphoneClipping])
        #expect(report.worstStatus == .caution)
    }

    @Test("A report whose every warning is unknown decodes to no warnings, not a failure")
    func allUnknownWarningsDecodeToEmpty() throws {
        let json = """
        {
          "warnings": ["futureA", "futureB"],
          "worstStatus": "atRisk",
          "microphoneStaleSeconds": 1.5,
          "systemAudioStaleSeconds": 2.5,
          "systemAudioEverDetected": false
        }
        """
        let report = try decode(RecordingHealthReport.self, json)
        #expect(report.warnings.isEmpty)
        // `worstStatus` survives the decode — but on its own that tells the user nothing, and an
        // earlier version of this test claimed otherwise. `RecordingHealthAdvisory.message` uses it
        // only as a gate and derives every word from `warnings`, so this decoded value reaches no
        // UI by itself. `aFlaggedReportWithNoKnownWarningsStillTellsTheUser` below is the test that
        // holds the user-visible half; this one only pins the wire decode.
        #expect(report.worstStatus == .atRisk)
        #expect(report.microphoneStaleSeconds == 1.5)
        #expect(report.systemAudioEverDetected == false)
    }

    @Test("A flagged report whose warnings were all dropped still tells the user something")
    func aFlaggedReportWithNoKnownWarningsStillTellsTheUser() throws {
        // The user-visible half of the lenient warning decode. Before F188's review, this case
        // rendered NOTHING: every note in `RecordingHealthAdvisory.message` reads `warnings`, so a
        // report flagged by a newer build whose only warning this build cannot name fell through to
        // `nil` — and the user was shown a clean recording precisely because it had been flagged.
        let report = RecordingHealthReport(
            warnings: [],
            worstStatus: .atRisk,
            microphoneStaleSeconds: 0,
            systemAudioStaleSeconds: 0,
            // True, so the `systemAudioEverDetected` note cannot fire and mask the gap.
            systemAudioEverDetected: true
        )
        let message = try #require(
            RecordingHealthAdvisory.message(for: report),
            "a flagged recording must never render as healthy"
        )
        #expect(message.contains("newer version"))
    }

    @Test("A healthy report still renders no advisory at all")
    func healthyReportStaysSilent() {
        // The guard above must not turn every clean recording into a warning.
        let report = RecordingHealthReport(
            warnings: [],
            worstStatus: .good,
            microphoneStaleSeconds: 0,
            systemAudioStaleSeconds: 0,
            systemAudioEverDetected: true
        )
        #expect(RecordingHealthAdvisory.message(for: report) == nil)
    }

    @Test("A report with a known warning is described, not given the fallback")
    func knownWarningKeepsItsOwnWording() throws {
        let report = RecordingHealthReport(
            warnings: [.lowStorage],
            worstStatus: .caution,
            microphoneStaleSeconds: 0,
            systemAudioStaleSeconds: 0,
            systemAudioEverDetected: true
        )
        let message = try #require(RecordingHealthAdvisory.message(for: report))
        #expect(message.contains("Storage ran low"))
        #expect(!message.contains("newer version"))
    }

    @Test("The on-disk shape of a health report is pinned, not just its round-trip")
    func healthReportWireShapeIsPinned() throws {
        // F188 asks for fixtures in BOTH directions. Every other test here decodes hand-written
        // JSON (an old reader meeting new bytes) or round-trips within one build, which says nothing
        // cross-version: a future refactor of `RecordingHealthReport` — `Set<Warning>` becoming an
        // array of objects, say — would pass all of them and reproduce F177 exactly. This asserts
        // the bytes this build WRITES. A single-warning report is used so the `Set` ordering is
        // deterministic.
        let report = RecordingHealthReport(
            warnings: [.lowStorage],
            worstStatus: .caution,
            microphoneStaleSeconds: 1.5,
            systemAudioStaleSeconds: 2,
            systemAudioEverDetected: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try #require(String(data: encoder.encode(report), encoding: .utf8))
        #expect(json == #"{"microphoneStaleSeconds":1.5,"systemAudioEverDetected":true,"systemAudioStaleSeconds":2,"warnings":["lowStorage"],"worstStatus":"caution"}"#)
    }

    @Test("A health report with only known warnings is unchanged")
    func knownHealthReportRoundTrips() throws {
        let original = RecordingHealthReport(
            warnings: [.systemAudioNotDetected, .lowStorage],
            worstStatus: .atRisk,
            microphoneStaleSeconds: 3,
            systemAudioStaleSeconds: 4,
            systemAudioEverDetected: true
        )
        let data = try JSONEncoder().encode(original)
        #expect(try decoder.decode(RecordingHealthReport.self, from: data) == original)
    }

    // MARK: MeetingTranscriptionEngine

    @Test("KNOWN GAP (F250): an unknown transcription engine still throws")
    func unknownTranscriptionEngineStillThrows() throws {
        // This is a characterization test, not an endorsement. It pins the one exposure from the
        // postmortem's list of three that F188 did NOT close, so the gap is visible in the suite
        // instead of living only in a ticket. When F250 lands, this test must be replaced by one
        // asserting the new behaviour — its failure is the reminder.
        //
        // Why it was not fixed alongside the two health types: `Decodable` cannot yield `nil` from a
        // type's own initialiser, and `decodeIfPresent` returns `nil` only for an absent or null
        // key, never for a value that throws. So enum-level leniency would have to invent a case,
        // and every candidate falsifies provenance — decoding an unrecognised engine as
        // `.whisperLarge` would claim a meeting was transcribed by a model that never touched it,
        // which is worse than failing. The honest fix is to persist the raw string and derive the
        // enum on read, which round-trips losslessly (F188's stated preference) but changes a
        // persisted field's type. That is F250.
        struct Holder: Decodable { var engine: MeetingTranscriptionEngine? }
        #expect(throws: DecodingError.self) {
            _ = try decode(Holder.self, #"{"engine":"whisper-cpp-large-v3"}"#)
        }
    }

    @Test("Known transcription engines still decode exactly")
    func knownTranscriptionEnginesRoundTrip() throws {
        struct Holder: Decodable { var engine: MeetingTranscriptionEngine? }
        #expect(try decode(Holder.self, #"{"engine":"large"}"#).engine == .whisperLarge)
        #expect(try decode(Holder.self, #"{"engine":"turbo"}"#).engine == .whisperTurbo)
        #expect(
            try decode(Holder.self, #"{"engine":"qwen3-asr-1.7b-8bit"}"#).engine == .qwenBalanced
        )
        #expect(try decode(Holder.self, #"{"engine":null}"#).engine == nil)
        #expect(try decode(Holder.self, "{}").engine == nil)
    }
}
