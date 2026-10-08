import Foundation
import IOKit

/// How busy the GPU is right now, as the graphics driver reports it (F890).
///
/// Quick Dictation's recognizer runs on the GPU through MLX, and it is the one resource the app
/// shares with everything else on the Mac that cannot be reserved: measured on 2026-10-08
/// (`Scripts/bench/dictation-latency.py`, condition L), a 3 s clip that decodes in 0.3 s on an idle
/// GPU takes 4.2–4.8 s beside another MLX process, while memory pressure, paging, CPU load, the
/// refiner's load/kill cycle and the helper's age all left it within 0.3–0.8 s. The user's own
/// dictations that day showed the same 10–30× spread. So the controller reads this just before
/// recognition: the "transcribed in" line names the busy GPU when the wait was its doing, and
/// refinement — a second, heavier model pass with a 0.8–1.5 s budget it would miss on a busy GPU —
/// is not attempted at all above `DictationController.refineSkipGPUBusyPercent`.
///
/// The number is the accelerator's `PerformanceStatistics["Device Utilization %"]` from the IOKit
/// registry: readable without privileges, sampled by the driver over its own recent window, and the
/// same figure Activity Monitor's GPU history draws. It is a whole-GPU figure — it cannot name the
/// process — and a single reading, so a compositing spike can show as a few tens of percent for an
/// instant. `nil` means the registry had no accelerator or no figure, never "idle": a caller that
/// cannot read the GPU must not act as though it were free.
enum GPUActivityProbe {
    static let statisticsKey = "PerformanceStatistics"
    static let utilizationKey = "Device Utilization %"

    /// The GPU's busy share, 0–100, or nil when it cannot be read.
    static func deviceUtilizationPercent() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            let property = IORegistryEntryCreateCFProperty(
                entry, statisticsKey as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue()
            if let statistics = property as? [String: Any],
               let utilization = utilization(in: statistics) {
                return utilization
            }
        }
        return nil
    }

    /// The utilization figure inside one accelerator's statistics dictionary, or nil when it is
    /// absent, not a number, or outside 0–100 (a figure that cannot be a percentage is not reported
    /// as one). Separated from the registry walk so the parse is testable without a GPU.
    static func utilization(in statistics: [String: Any]) -> Int? {
        guard let number = statistics[utilizationKey] as? NSNumber else { return nil }
        let value = number.intValue
        guard (0...100).contains(value) else { return nil }
        return value
    }
}
