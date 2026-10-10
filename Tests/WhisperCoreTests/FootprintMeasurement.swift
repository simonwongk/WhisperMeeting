import Foundation

// The harness F533 (round 2) and F910 measure memory with: what ONE direct call left held, read
// just before and just after it.
//
// Never the process-wide peak (`ru_maxrss`, `ledger_phys_footprint_peak`). An earlier test in the
// same process can already have raised it, and then a later hold reads as smaller than it is. That
// happened in the lane L review: a run that held about 418 MB reported a peak growth of 286 MB,
// because the test before it had already raised the peak.
//
// The current footprint can be masked too, which the review did not expect. Measured in one
// process on 2026-10-09 (F533 round 2): a loop that kept all 64 MiB it read grew
// the footprint by 66,355,248 bytes, but the same loop run again straight afterwards grew it by 0.
// malloc had kept the first loop's freed blocks, still counted in the footprint, and the second
// reused them. `malloc_zone_pressure_relief` released none of it. The bytes malloc has handed out
// and not had back grew by 67,111,728 and then 67,110,992: those cannot be hidden by anything an
// earlier test freed, because reusing a freed block allocates it again. So both are read.

/// What one call left held.
struct HeldMemory: CustomStringConvertible {
    /// Growth in the process's current physical footprint: dirty memory as the system counts it,
    /// including anything not allocated through malloc. Can read low after an earlier test.
    let footprint: Int
    /// Growth in the bytes malloc has allocated and not had back, in every zone. Cannot be masked
    /// by memory an earlier test freed.
    let allocated: Int

    var description: String { "footprint +\(footprint) bytes, allocated +\(allocated) bytes" }
}

/// This process's current physical footprint in bytes (`task_info(TASK_VM_INFO).phys_footprint`):
/// the dirty and compressed memory it holds now. Clean file-backed pages are not counted, so reading
/// or writing a file does not move it by itself. Only buffers the process still holds do.
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

/// What `body` left held when it returned.
///
/// Both readings are taken inside one autorelease pool, which is drained only after the second
/// reading. So anything `body` autoreleased and left in its caller's pool is counted. In the app,
/// that memory stays held until the job that made the call ends.
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

/// Writes `mebibytes` MiB of float32 samples in (-0.5, 0.5) from a fixed-seed generator: dense
/// (every block on disk, nothing sparse), never silent, never NaN, and the same bytes for the same
/// seed on every run. Written one MiB at a time, each in its own pool, so writing the fixture holds
/// nothing itself.
func writeDenseFile(at url: URL, mebibytes: Int, seed: UInt32) throws {
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let writer = try FileHandle(forWritingTo: url)
    defer { try? writer.close() }
    var state = seed
    for _ in 0..<mebibytes {
        try autoreleasepool {
            var samples = [Float](repeating: 0, count: (1 << 20) / MemoryLayout<Float>.size)
            for index in samples.indices {
                state = state &* 1_664_525 &+ 1_013_904_223
                samples[index] = Float(Int32(bitPattern: state) >> 8) / Float(1 << 24)
            }
            try samples.withUnsafeBytes { try writer.write(contentsOf: Data($0)) }
        }
    }
}
