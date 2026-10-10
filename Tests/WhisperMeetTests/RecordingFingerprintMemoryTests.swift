import CryptoKit
import Foundation
import Testing
@testable import WhisperMeet

// F910 — `RecordingFingerprint.sha256` hashes a meeting's whole recording after speaker analysis,
// 1 MiB at a time, inside one `Task.detached` job (`AppModel.performSpeakerDiarization`).
// `FileHandle.read(upToCount:)` returns each chunk in an autoreleased buffer, and with no pool
// drained per chunk every chunk stayed allocated until the hash returned: +66,388,016 bytes of
// footprint across one call over a 64 MiB file, so a three-hour meeting's ~1 GB `meeting.wav` was
// held whole.
//
// Measured with `heldMemory` (`HeldMemory.swift`): what ONE direct call left held, as the current
// footprint and as the bytes malloc has allocated, which an earlier test cannot mask.

@Test("Fingerprinting a recording holds one chunk of it at a time, not all of it (F910)")
func fingerprintingARecordingHoldsOneChunkAtATime() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("F910-fingerprint-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try writeDenseFile(at: url, mebibytes: 64, seed: 910)

    var digest = ""
    let held = try heldMemory { digest = try RecordingFingerprint.sha256(of: url) }

    let mapped = try Data(contentsOf: url, options: .alwaysMapped)
    #expect(digest == SHA256.hash(data: mapped).map { String(format: "%02x", $0) }.joined())
    // Every chunk kept is the whole 64 MiB; one chunk at a time is about 1 MiB.
    #expect(held.allocated < 16 << 20, "fingerprinting a 64 MiB recording left \(held) held")
    #expect(held.footprint < 16 << 20, "fingerprinting a 64 MiB recording left \(held) held")
}
