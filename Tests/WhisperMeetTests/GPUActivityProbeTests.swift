import Foundation
import Testing
@testable import WhisperMeet

/// F890 — the GPU-busy reading the controller takes before recognition. The registry walk is
/// host-dependent and is only checked for its contract (nil, or a percentage); the parse of the
/// accelerator's statistics dictionary is pinned exactly.

@Test("The accelerator's Device Utilization figure is read as a whole percentage")
func utilizationIsReadFromTheStatisticsDictionary() {
    #expect(GPUActivityProbe.utilization(in: ["Device Utilization %": 37]) == 37)
    #expect(GPUActivityProbe.utilization(in: ["Device Utilization %": NSNumber(value: 100)]) == 100)
    #expect(GPUActivityProbe.utilization(in: ["Device Utilization %": 0]) == 0)
}

@Test("A missing, non-numeric or impossible figure reads as nil, never as idle")
func unreadableFigureIsNil() {
    #expect(GPUActivityProbe.utilization(in: [:]) == nil)
    #expect(GPUActivityProbe.utilization(in: ["Renderer Utilization %": 50]) == nil)
    #expect(GPUActivityProbe.utilization(in: ["Device Utilization %": "47"]) == nil)
    #expect(GPUActivityProbe.utilization(in: ["Device Utilization %": -1]) == nil)
    #expect(GPUActivityProbe.utilization(in: ["Device Utilization %": 101]) == nil)
}

@Test("The live reading is nil or a percentage on every host")
func liveReadingIsNilOrAPercentage() {
    // Not asserting a value: what the GPU is doing is this machine's business. Only the contract
    // the controller relies on — a reading it can compare against a threshold, or none.
    if let reading = GPUActivityProbe.deviceUtilizationPercent() {
        #expect((0...100).contains(reading))
    }
}
