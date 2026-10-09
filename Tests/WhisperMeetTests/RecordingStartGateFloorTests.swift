import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F744 — `AppModel.startRecording` refused a start below a literal `500_000_000` and said "less than
// 500 MB", while F597 made the live low-storage warning's floor
// `RecordingHealthMonitor.lowStorageFloorBytes`, whose doc said "Change both together". Two copies
// of one number drift, and then the gate and the warning disagree again: a recording starts in a
// band it is warned about at once, or runs below what the gate calls at risk with nothing said.
//
// Pinned as source, with comments stripped (F285). The gate cannot be driven: `startRecording`
// refreshes the preflight from the real volume just before it, and no figure a test could choose
// would tell the literal from the constant while both are 500 MB, which is the whole defect.

@Test("Recording's start gate compares against the live warning's floor and names it, with no literal of its own (F744)")
func theStartGateUsesTheLowStorageFloor() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppModel.swift")
    let start = try #require(source.range(of: "func startRecording() async {"))
    // The gates come before the first side effect, which is moving to `.starting`.
    let end = try #require(source.range(of: "recordingState = .starting", range: start.upperBound..<source.endIndex))
    let gates = source[start.upperBound..<end.lowerBound]
    #expect(gates.contains("available < RecordingHealthMonitor.lowStorageFloorBytes"),
            "the start gate must compare against the floor the live warning uses")
    #expect(!gates.contains("500_000_000"), "the start gate restates the floor as a literal")
    #expect(!gates.contains("500 MB"), "the refusal restates the floor as a literal")
    #expect(gates.contains("\\(RecordingHealthMonitor.lowStorageFloorBytes / 1_000_000) MB"),
            "the refusal names the floor it enforces")
}
