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
// Measured as WhisperCoreTests' `heldMemory` measures (`FootprintMeasurement.swift`): what ONE direct
// call left held, as the current footprint and as the bytes malloc has allocated. The second cannot
// be masked by memory an earlier test freed; the first can. The two test targets share no code, so
// the two readings are repeated here.

private func currentPhysicalFootprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return -1 }
    return Int(clamping: info.phys_footprint)
}

private func currentlyAllocatedBytes() -> Int {
    var statistics = malloc_statistics_t()
    malloc_zone_statistics(nil, &statistics)
    return Int(clamping: statistics.size_in_use)
}

@Test("Fingerprinting a recording holds one chunk of it at a time, not all of it (F910)")
func fingerprintingARecordingHoldsOneChunkAtATime() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("F910-fingerprint-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    // 64 MiB of fixed-seed bytes, dense, written one MiB at a time so writing it holds nothing.
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
    let writer = try FileHandle(forWritingTo: url)
    var state: UInt32 = 910
    for _ in 0..<64 {
        try autoreleasepool {
            var words = [UInt32](repeating: 0, count: (1 << 20) / MemoryLayout<UInt32>.size)
            for index in words.indices {
                state = state &* 1_664_525 &+ 1_013_904_223
                words[index] = state
            }
            try words.withUnsafeBytes { try writer.write(contentsOf: Data($0)) }
        }
    }
    try writer.close()

    var digest = ""
    let (footprint, allocated): (Int, Int) = try autoreleasepool {
        let footprint = currentPhysicalFootprint()
        let allocated = currentlyAllocatedBytes()
        digest = try RecordingFingerprint.sha256(of: url)
        return (currentPhysicalFootprint() - footprint, currentlyAllocatedBytes() - allocated)
    }

    let mapped = try Data(contentsOf: url, options: .alwaysMapped)
    #expect(digest == SHA256.hash(data: mapped).map { String(format: "%02x", $0) }.joined())
    // Every chunk kept is the whole 64 MiB; one chunk at a time is about 1 MiB.
    #expect(allocated < 16 << 20, "fingerprinting a 64 MiB recording left +\(allocated) bytes allocated")
    #expect(footprint < 16 << 20, "fingerprinting a 64 MiB recording left +\(footprint) bytes of footprint")
}
