import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F510 — `installQwenASR` refuses while `isRunningAuxiliaryEngine` (F140); `installLocalWhisper`
// never learned the same lesson, and neither Settings button was disabled for it. A second opinion
// of a Qwen transcript, or a Whisper segment re-run, executes `Runtime/venv/bin/whisper` while
// `setup-local-whisper.sh` moves that venv aside and `rm -rf`'s it — so "Repair or Update" on the
// Whisper row can delete the very environment a running auxiliary pass depends on, while the
// Qwen row's own button sits enabled beside it and would silently no-op if pressed.
//
// Shaped like F228's own coverage of the same hole (`DiarizationInstallWiringTests`,
// "The other three model installers refuse while speaker analysis is installing"): in the test
// bundle `Bundle.main.url(forResource:)` finds no installer script, so a guard that lets the call
// through reaches "…installer is missing"; a guard that refuses leaves `alertMessage` nil. The
// control at the end lets the same call through once the auxiliary run ends, so the refusal above
// is shown to be the guard's doing and not a call that could never have done anything.

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

/// Holds one engine pass open until the test lets it finish (the F470 suite's own shape).
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var open = false
    func enter() { lock.withLock { entered = true } }
    var hasEntered: Bool { lock.withLock { entered } }
    func release() { lock.withLock { open = true } }
    var isOpen: Bool { lock.withLock { open } }
}

@MainActor
private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    var ticks = 0
    while !condition(), ticks < 6_000 {
        try await Task.sleep(nanoseconds: 5_000_000)
        ticks += 1
    }
    try #require(condition(), "timed out waiting for \(what)")
}

@MainActor
private func settle() async {
    for _ in 0..<200 { await Task.yield() }
}

/// A completed meeting whose second opinion the gate holds open.
@MainActor
private func makeModel() throws -> (model: AppModel, id: UUID, gate: Gate) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F510-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Recordings"), withIntermediateDirectories: true)
    let defaults = try #require(UserDefaults(suiteName: "F510.\(UUID().uuidString)"))
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults,
                         whisperExecutable: { URL(fileURLWithPath: "/usr/bin/true") }, qwenInstalled: { true })
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "Held", recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed, transcriptText: "held", segments: [seg("held", 0, 2)],
        transcriptionEngine: .whisperLarge
    ))
    let gate = Gate()
    model.runTranscriptionEngineOverride = { _, _ in
        gate.enter()
        while !gate.isOpen { try await Task.sleep(nanoseconds: 2_000_000) }
        return TranscriptionResult(id: "stub", text: "held", languageCode: "en", audioDuration: 2,
                                   confidence: nil, segments: [seg("held", 0, 2)])
    }
    return (model, id, gate)
}

@MainActor
@Test("installLocalWhisper refuses while a second opinion or segment re-run is in flight (F510)")
func installLocalWhisperRefusesWhileAuxiliaryEngineRuns() async throws {
    let (model, id, gate) = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    model.requestSecondOpinion(id: id)
    try await waitUntil("the second opinion to reach its engine") { gate.hasEntered }
    #expect(model.isRunningAuxiliaryEngine)

    model.installLocalWhisper()
    await settle()

    #expect(model.alertMessage == nil, "installLocalWhisper ran while an auxiliary engine pass was in flight")
    #expect(!model.isInstallingRuntime)

    gate.release()
    try await waitUntil("the second opinion to finish") { !model.isRunningAuxiliaryEngine }

    // The control: with nothing in flight the same call goes through and reaches the
    // missing-installer-script branch, so the refusal above was the guard and not a no-op call.
    model.installLocalWhisper()
    await settle()
    #expect(model.alertMessage?.contains("installer is missing") == true)
}

@Test("Both install-or-repair buttons in Settings are disabled while an auxiliary engine pass runs (F510, F514)")
func settingsDisablesBothInstallButtonsDuringAnAuxiliaryRun() throws {
    // The view has no render harness (F174), so the wiring is pinned against the source, comments
    // stripped so an explanation cannot satisfy it (F285's false positive).
    //
    // F514 replaced the hand-written six-condition list this test originally pinned with the one
    // shared `recognitionRuntimeInstallBlockedReason` property (which itself asks
    // `isRunningAuxiliaryEngine`, among the same six) — asserted directly against
    // `AppModel.recognitionRuntimeInstallBlockedReason`'s own behaviour below, and here only that
    // both buttons actually consult it.
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    #expect(source.contains(
        "Button(model.isRuntimeInstalled ? \"Repair or Update\" : \"Install Local Whisper\") { model.installLocalWhisper() } .buttonStyle(.bordered)"
    ))
    #expect(source.contains(
        "Button(model.isQwenInstalled ? \"Repair or Update\" : \"Install Qwen3-ASR\") { model.installQwenASR() } .buttonStyle(.bordered) .disabled(model.recognitionRuntimeInstallBlockedReason != nil)"
    ), "the Qwen row's button is not disabled on the shared install-blocked reason")
    let wholeSource = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let occurrences = wholeSource.components(separatedBy: "model.recognitionRuntimeInstallBlockedReason != nil").count - 1
    #expect(occurrences >= 2, "expected both Settings buttons to consult the shared reason, found \(occurrences) uses")
}

@Test("installLocalWhisper and installQwenASR derive their guard from the shared reason, not a second list (F514)")
func installGuardsDeriveFromTheSharedReason() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppModel.swift")
    let installFuncs = ["func installLocalWhisper()", "func installQwenASR()"]
    for marker in installFuncs {
        guard let range = source.range(of: marker) else {
            Issue.record("\(marker) not found")
            continue
        }
        let after = source[range.upperBound...].prefix(300)
        #expect(after.contains("recognitionRuntimeInstallBlockedReason"),
                "\(marker) does not consult the shared reason")
    }
}

// F514 — `recognitionRuntimeInstallBlockedReason` itself: nil when idle, and named (not merely
// non-nil) for the two conditions this ticket is about — an auxiliary engine run and Quick
// Dictation — so the Dictation tab's footnote says the true reason rather than a generic one.

@MainActor
@Test("recognitionRuntimeInstallBlockedReason is nil on an idle model (F514)")
func recognitionRuntimeInstallBlockedReasonIsNilWhenIdle() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F514-idle-\(UUID().uuidString)")
    let defaults = try #require(UserDefaults(suiteName: "F514.idle.\(UUID().uuidString)"))
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    #expect(model.recognitionRuntimeInstallBlockedReason == nil)
}

@MainActor
@Test("recognitionRuntimeInstallBlockedReason names a running auxiliary engine pass (F514)")
func recognitionRuntimeInstallBlockedReasonNamesTheAuxiliaryRun() async throws {
    let (model, id, gate) = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    model.requestSecondOpinion(id: id)
    try await waitUntil("the second opinion to reach its engine") { gate.hasEntered }

    let reason = try #require(model.recognitionRuntimeInstallBlockedReason)
    #expect(reason.contains("second opinion"), "\(reason)")

    gate.release()
    try await waitUntil("the second opinion to finish") { !model.isRunningAuxiliaryEngine }
}

@MainActor
@Test("recognitionRuntimeInstallBlockedReason names Quick Dictation (F514)")
func recognitionRuntimeInstallBlockedReasonNamesDictation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F514-dictation-\(UUID().uuidString)")
    let defaults = try #require(UserDefaults(suiteName: "F514.dictation.\(UUID().uuidString)"))
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    model.configureDictationGuard { true }

    let reason = try #require(model.recognitionRuntimeInstallBlockedReason)
    #expect(reason.contains("Quick Dictation"), "\(reason)")
}

// F514 — the Dictation tab's own wiring: both buttons disabled on the shared reason, and a
// footnote beside them (not inside either button) names it. `DictationView` has no render harness
// (F174), so this is a source assertion, comments stripped (F285).

@Test("The Dictation tab disables both install buttons on the shared reason and shows why (F514)")
func dictationTabWiresTheSharedReason() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/DictationView.swift")
        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    #expect(source.contains(
        "Button(\"Install / Repair Qwen3-ASR\") { model.installQwenASR() } .disabled(model.recognitionRuntimeInstallBlockedReason != nil)"
    ))
    #expect(source.contains(
        "Button(\"Install / Repair Local Whisper\") { model.installLocalWhisper() } .disabled(model.recognitionRuntimeInstallBlockedReason != nil)"
    ))
    #expect(source.contains("let reason = model.recognitionRuntimeInstallBlockedReason"),
            "no footnote reads the shared reason")
    #expect(source.contains("Text(reason)"), "the footnote does not show the reason text")
}
