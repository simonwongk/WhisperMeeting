import Foundation

// WhisperMeetTests' copy of the memory harness in `Tests/WhisperCoreTests/FootprintMeasurement.swift`
// (F533 round 2; F910, F927). It reads what ONE direct call left held, two ways: the current footprint,
// and the bytes malloc has allocated. The footprint alone can be masked by an earlier test, because malloc
// keeps blocks it was given back, still counted, and a loop that keeps every chunk can reuse them without
// the footprint growing at all. Allocated bytes cannot be hidden that way: reusing a freed block allocates
// it again. The two test targets share no code, so the readings are repeated here, once for this target.

/// What one call left held.
struct HeldMemory: CustomStringConvertible {
    /// Growth in the process's current physical footprint. Can read low after an earlier test.
    let footprint: Int
    /// Growth in the bytes malloc has allocated and not had back, in every zone.
    let allocated: Int

    var description: String { "footprint +\(footprint) bytes, allocated +\(allocated) bytes" }
}

/// This process's current physical footprint in bytes (`task_info(TASK_VM_INFO).phys_footprint`).
func currentPhysicalFootprint() -> Int {
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

/// The bytes malloc has allocated and not had back, across every zone (`malloc_zone_statistics`).
func currentlyAllocatedBytes() -> Int {
    var statistics = malloc_statistics_t()
    malloc_zone_statistics(nil, &statistics)
    return Int(clamping: statistics.size_in_use)
}

/// What `body` left held when it returned. Both readings are taken inside one autorelease pool that
/// is drained only afterwards, so anything `body` autoreleased and left in its caller's pool counts —
/// in the app that memory stays held until the job that made the call ends.
func heldMemory(across body: () throws -> Void) rethrows -> HeldMemory {
    try autoreleasepool {
        let footprint = currentPhysicalFootprint()
        let allocated = currentlyAllocatedBytes()
        try body()
        return HeldMemory(
            footprint: currentPhysicalFootprint() - footprint,
            allocated: currentlyAllocatedBytes() - allocated
        )
    }
}

/// Writes `mebibytes` MiB of fixed-seed bytes: dense (every block on disk), the same for the same seed
/// on every run, written one MiB at a time, each in its own pool, so writing the fixture holds nothing.
func writeDenseFile(at url: URL, mebibytes: Int, seed: UInt32) throws {
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let writer = try FileHandle(forWritingTo: url)
    defer { try? writer.close() }
    var state = seed
    for _ in 0..<mebibytes {
        try autoreleasepool {
            var words = [UInt32](repeating: 0, count: (1 << 20) / MemoryLayout<UInt32>.size)
            for index in words.indices {
                state = state &* 1_664_525 &+ 1_013_904_223
                words[index] = state
            }
            try words.withUnsafeBytes { try writer.write(contentsOf: Data($0)) }
        }
    }
}
