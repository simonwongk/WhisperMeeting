import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F509 — a Homebrew or pipx `whisper` older than openai-whisper 20250625 is accepted by
// `findExecutable()` with no version check, and `commandArguments` unconditionally adds
// `--carry_initial_prompt` the moment a meeting has any vocabulary term, which such a build
// rejects at argparse. `LocalWhisperRuntimeTests` covers the pure probe; this covers that
// `AppModel` actually asks it and stops sending vocabulary a discovered runtime cannot accept,
// which the reachability rule (AGENTS.md) requires beyond a tested-but-uncalled core.
//
// **Follow-up (review round 2).** The probe itself spawns `whisper --help` and blocks on
// `waitUntilExit()` — measured against the real installed executable at ~1.0-1.1 s wall-clock (an
// independent reviewer measured 0.859 s on the app's own binary), not the "few tens of
// milliseconds" the first version of this fix assumed. `refreshRuntime()` called it synchronously
// on the main actor, and `beginTranscription(id:)` calls `refreshRuntime()` for every job, so
// `beginTranscriptionForAllReady()` over N queued meetings spawned N blocking subprocesses on the
// UI thread — freezing the app for roughly N seconds before any transcription even started.
// `AppModel.updateVocabularyPromptSupport` now memoizes the result per executable (path +
// modification date) and runs the first probe off the main actor via `Task.detached`; until it
// lands, `runtimeSupportsVocabularyPrompt` is `nil` ("not yet known"), and every reader — the
// keyterms gate and the Settings notice alike — treats `nil` exactly like `false`: omit the
// vocabulary, say nothing, never block to find out.

/// A bounded poll whose own success is the assertion's subject (never a stand-in for a fixed
/// sleep) — the `QueuedBehindAuxiliaryRunTests` precedent. The cap is a ceiling, not a budget: the
/// probe lands on a `.utility` detached task, and after ~570 other tests on a loaded Mac it took
/// longer than the former 3 s, failing a correct test (F866). A passing run still returns as soon
/// as the condition holds.
@MainActor
private func waitUntil(_ what: String, timeoutSeconds: Double = 30, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while !condition(), Date() < deadline {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    try #require(condition(), "timed out waiting for \(what)")
}

private final class ProbeCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func increment() { lock.withLock { calls += 1 } }
    var count: Int { lock.withLock { calls } }
}

/// Holds the probe closure open until the test releases it, so a caller that (wrongly) blocks on
/// the probe can be told apart from one that does not.
private final class ProbeLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var released = false
    func markEntered() { lock.withLock { entered = true } }
    var hasEntered: Bool { lock.withLock { entered } }
    func release() { lock.withLock { released = true } }
    /// Busy-polls off the main actor (this always runs inside the probe, i.e. inside
    /// `Task.detached` once the fix is in place) until released.
    func waitUntilReleased() {
        while !(lock.withLock { released }) {
            usleep(2_000)
        }
    }
}

@MainActor
private func makeModel(
    suite: String,
    supportsCarryInitialPrompt: Bool
) -> (AppModel, UserDefaults, String) {
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("VocabularyPromptCapabilityTests-\(UUID().uuidString)")
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: defaults,
        whisperExecutable: { URL(fileURLWithPath: "/tmp/whisper-F509-fixture") },
        qwenInstalled: { false },
        // Passed at construction, not assigned after: `init` fires the first probe itself, before
        // a post-construction assignment could possibly land in time — see the parameter's own
        // doc comment on `AppModel.init`.
        carryInitialPromptSupport: { _ in supportsCarryInitialPrompt }
    )
    return (model, defaults, suite)
}

/// A model with one meeting already queued and ready to transcribe, wired so
/// `beginTranscription`/`beginTranscriptionForAllReady` never touch a real engine.
@MainActor
private func makeQueueableModel(
    suite: String,
    carryInitialPromptSupport: @escaping @Sendable (URL) -> Bool = { _ in true }
) throws -> (model: AppModel, meetingID: UUID, defaults: UserDefaults) {
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("VocabularyPromptCapabilityTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Recordings"), withIntermediateDirectories: true
    )
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: defaults,
        // A real path so `isExecutableFile`/`isRuntimeInstalled` read true without touching the
        // real Whisper venv — the F470/F262 test precedent.
        whisperExecutable: { URL(fileURLWithPath: "/usr/bin/true") },
        qwenInstalled: { false },
        // Passed at construction (see AppModel.init's own note): `init` fires the first probe
        // itself, so a caller that wants to observe or control THAT probe (not a later,
        // already-cached one) must supply it here, not assign the property afterwards.
        carryInitialPromptSupport: carryInitialPromptSupport
    )
    model.selectedEngine = .whisperLarge
    model.runTranscriptionEngineOverride = { _, _ in
        TranscriptionResult(id: "stub", text: "stub", languageCode: "en", audioDuration: 1,
                            confidence: nil, segments: [])
    }
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "Ready",
        recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .recorded
    ))
    return (model, id, defaults)
}

@MainActor
@Test("A capable runtime reports no vocabulary caveat, even with vocabulary present (F509)")
func capableRuntimeReportsNoVocabularyCaveat() async throws {
    let (model, defaults, suite) = makeModel(suite: "F509.capable", supportsCarryInitialPrompt: true)
    defer { defaults.removePersistentDomain(forName: suite) }
    model.store.addVocabulary(["WhisperMeet"])

    try await waitUntil("the probe to land") { model.runtimeSupportsVocabularyPrompt != nil }
    #expect(model.runtimeSupportsVocabularyPrompt == true)
    #expect(model.vocabularyPromptUnsupportedNotice == nil)
}

@MainActor
@Test("An incapable runtime names the fix only once vocabulary would actually be sent (F509)")
func incapableRuntimeNoticeNeedsVocabularyPresent() async throws {
    let (model, defaults, suite) = makeModel(suite: "F509.incapableEmpty", supportsCarryInitialPrompt: false)
    defer { defaults.removePersistentDomain(forName: suite) }

    try await waitUntil("the probe to land") { model.runtimeSupportsVocabularyPrompt != nil }
    #expect(model.runtimeSupportsVocabularyPrompt == false)
    // No vocabulary terms yet, so nothing would be omitted — no caveat to show.
    #expect(model.vocabularyPromptUnsupportedNotice == nil)

    model.store.addVocabulary(["Acme Corp"])
    #expect(model.vocabularyPromptUnsupportedNotice != nil)
    #expect(model.vocabularyPromptUnsupportedNotice!.contains("20250625"))
}

@MainActor
@Test("No installed runtime is not itself a vocabulary caveat (F509)")
func missingRuntimeReportsNoVocabularyCaveat() {
    let defaults = UserDefaults(suiteName: "F509.missing")!
    defaults.removePersistentDomain(forName: "F509.missing")
    defer { defaults.removePersistentDomain(forName: "F509.missing") }
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("VocabularyPromptCapabilityTests-\(UUID().uuidString)")
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: defaults,
        whisperExecutable: { nil },
        qwenInstalled: { false }
    )
    model.store.addVocabulary(["Acme Corp"])

    // No executable at all resolves synchronously — there is nothing to probe.
    #expect(model.runtimeSupportsVocabularyPrompt == true)
    #expect(model.vocabularyPromptUnsupportedNotice == nil)
}

@MainActor
@Test("The --carry_initial_prompt probe runs once across many queued beginTranscription calls (F509)")
func probeRunsOnceAcrossManyBeginTranscriptionCalls() async throws {
    let suite = testSuiteName()
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("VocabularyPromptCapabilityTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Recordings"), withIntermediateDirectories: true
    )
    let counter = ProbeCallCounter()
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: defaults,
        whisperExecutable: { URL(fileURLWithPath: "/usr/bin/true") },
        qwenInstalled: { false },
        // Passed at construction — see AppModel.init's own note on why a post-construction
        // assignment races init's own first probe instead of replacing it.
        carryInitialPromptSupport: { _ in
            counter.increment()
            return true
        }
    )
    model.selectedEngine = .whisperLarge
    model.runTranscriptionEngineOverride = { _, _ in
        TranscriptionResult(id: "stub", text: "stub", languageCode: "en", audioDuration: 1,
                            confidence: nil, segments: [])
    }

    // Five separate meetings, each `beginTranscription(id:)` (via `beginTranscriptionForAllReady`)
    // calls `refreshRuntime()` for — the exact shape that used to spawn one blocking `whisper
    // --help` per meeting.
    for index in 0..<5 {
        let id = UUID()
        model.store.upsert(MeetingRecord(
            id: id, title: "Meeting \(index)",
            recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
            status: .recorded
        ))
    }
    let queued = model.beginTranscriptionForAllReady()
    #expect(queued == 5)

    try await waitUntil("the probe to land") { model.runtimeSupportsVocabularyPrompt != nil }
    #expect(counter.count == 1, "expected the probe closure to run once; ran \(counter.count) times")
}

@MainActor
@Test("beginTranscription returns without waiting for a slow --carry_initial_prompt probe (F509)")
func beginTranscriptionDoesNotBlockOnASlowProbe() async throws {
    let suite = testSuiteName()
    let latch = ProbeLatch()
    let (model, id, defaults) = try makeQueueableModel(
        suite: suite,
        // Passed at construction: `init` fires this probe itself (off the main actor) the moment
        // the model exists, and it is still in flight — blocked on the latch — by the time
        // `beginTranscription` below runs its own `refreshRuntime()`, which is exactly the
        // scenario under test: a second caller arriving while the first probe has not landed must
        // not wait for it either.
        carryInitialPromptSupport: { _ in
            latch.markEntered()
            // Stands in for the real ~1 s `whisper --help` block. This must run OFF the main actor
            // (inside `Task.detached`) — if the probe is ever again called synchronously on the
            // main actor, this line never returns and the test hangs instead of failing an
            // assertion, which is itself the signal: `Scripts/quality-check.sh`'s own [3/5]
            // watchdog exists for exactly this shape of regression.
            latch.waitUntilReleased()
            return true
        }
    )
    defer { defaults.removePersistentDomain(forName: suite) }

    model.beginTranscription(id: id) // must return immediately, though a probe is already blocked

    // The latch has not been released yet, so the probe cannot possibly have finished — proving
    // the call above did not wait for it. This is the state check the review asked for in place of
    // a clock: "beginTranscription returns before the latch opens."
    #expect(
        model.runtimeSupportsVocabularyPrompt == nil,
        "beginTranscription must not synchronously wait for the --carry_initial_prompt probe"
    )

    try await waitUntil("the probe to have been entered") { latch.hasEntered }
    latch.release()
    try await waitUntil("the probe result to land") { model.runtimeSupportsVocabularyPrompt != nil }
    #expect(model.runtimeSupportsVocabularyPrompt == true)
}
