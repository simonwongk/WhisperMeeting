import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

/// F200 — the controller's refinement wiring, driven headlessly through the injected seams
/// (fake recorder/overlay/monitor/engine/refiner). Delivery runs clipboard-only
/// (`dictationAutoPaste=false`) so no Accessibility or paste events are involved.

@MainActor
private struct Harness {
    let controller: DictationController
    let monitor: FakeHotkeyMonitor
    let refiner: FakeRefiner
    let defaults: UserDefaults
    let suite: String
    let directory: URL

    init(
        engineText: String = "hello there",
        refineEnabled: Bool,
        runtimeAvailable: Bool = true,
        idleEvictSeconds: TimeInterval = 300
    ) throws {
        suite = "WhisperMeet.DictationRefinementWiringTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationRefinementWiringTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults.set(true, forKey: "dictationEnabled")
        defaults.set(false, forKey: "dictationAutoPaste")
        defaults.set(refineEnabled, forKey: "dictationRefineEnabled")
        monitor = FakeHotkeyMonitor()
        refiner = FakeRefiner()
        controller = DictationController(
            defaults: defaults,
            engine: FixedTextDictationEngine(text: engineText),
            recorder: FakeDictationRecorder(outputURL: directory.appendingPathComponent("c.wav")),
            overlay: SilentDictationOverlay(),
            hotkeyMonitor: monitor,
            logStore: DictationLogStore(directory: directory),
            captureSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            refiner: refiner,
            textInjector: isolatedTextInjector(),
            idleEvictSeconds: idleEvictSeconds,
            activateOnInit: false
        )
        controller.refineRuntimeAvailability = { runtimeAvailable }
        controller.clipboardNotifier = {} // UNUserNotificationCenter crashes without an app bundle
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    /// One full press-talk-release cycle, waiting until the delivery lands in the log.
    func dictateOnce() async throws {
        monitor.onPressStart?()
        try await Task.sleep(for: .milliseconds(20))
        monitor.onPressEnd?()
        for _ in 0..<300 where controller.logStore.log.entries.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!controller.logStore.log.entries.isEmpty)
    }

    /// The polish model is deliberately optional: dictation must run once in an idle period before
    /// the controller starts it in the background. Enable the controller here to exercise the
    /// separate, already-warm refinement path without making a press-down compete with ASR.
    func warmRefiner() async throws {
        controller.setEnabled(true)
        for _ in 0..<300 where refiner.warmUpCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(refiner.warmUpCount >= 1)
        // `warmUp()` increments the fake's counter just before the controller records its ready
        // state on the main actor. Yield that completion before starting the capture below.
        for _ in 0..<5 { await Task.yield() }
    }
}

@MainActor
@Test("Refine off: the refiner is never consulted and raw text is delivered")
func refineOffNeverTouchesRefiner() async throws {
    let harness = try Harness(refineEnabled: false)
    defer { harness.tearDown() }
    try await harness.dictateOnce()
    #expect(harness.refiner.attemptCount == 0)
    let entry = harness.controller.logStore.log.entries.first
    #expect(entry?.text == "hello there")
    #expect(entry?.refinement == nil)
    #expect(entry?.rawText == nil)
}

@MainActor
@Test("Refine on + refined outcome: refined text is delivered; log keeps the raw transcript")
func refinedTextDeliveredAndLogged() async throws {
    let harness = try Harness(refineEnabled: true)
    defer { harness.tearDown() }
    harness.refiner.script(RefineAttempt(text: "Hello there.", outcome: .refined))
    try await harness.warmRefiner()
    try await harness.dictateOnce()
    #expect(harness.refiner.attemptCount == 1)
    let entry = harness.controller.logStore.log.entries.first
    #expect(entry?.text == "Hello there.")
    #expect(entry?.rawText == "hello there")
    #expect(entry?.refinement == "refined")
    #expect(entry?.outcome == .clipboard)
}

@MainActor
@Test("Refine on + timeout outcome: raw is delivered and the outcome recorded")
func timeoutDeliversRaw() async throws {
    let harness = try Harness(refineEnabled: true)
    defer { harness.tearDown() }
    harness.refiner.script(RefineAttempt(text: "hello there", outcome: .rawTimeout))
    try await harness.warmRefiner()
    try await harness.dictateOnce()
    let entry = harness.controller.logStore.log.entries.first
    #expect(entry?.text == "hello there")
    #expect(entry?.rawText == nil)
    #expect(entry?.refinement == "rawTimeout")
}

@MainActor
@Test("Refine on but runtime unavailable: the refiner is never consulted")
func unavailableRuntimeSkips() async throws {
    let harness = try Harness(refineEnabled: true, runtimeAvailable: false)
    defer { harness.tearDown() }
    try await harness.dictateOnce()
    #expect(harness.refiner.attemptCount == 0)
    #expect(harness.controller.logStore.log.entries.first?.refinement == nil)
}

@MainActor
@Test("Press-down defers optional refinement until raw dictation has been delivered")
func pressDownDefersRefinerWarmUp() async throws {
    let on = try Harness(refineEnabled: true)
    defer { on.tearDown() }
    on.monitor.onPressStart?()
    try await Task.sleep(for: .milliseconds(50))
    #expect(on.refiner.warmUpCount == 0)
    on.monitor.onPressEnd?()
    for _ in 0..<300 where on.controller.logStore.log.entries.isEmpty {
        try await Task.sleep(for: .milliseconds(10))
    }
    for _ in 0..<100 where on.refiner.warmUpCount == 0 {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(on.refiner.warmUpCount == 1)

    let off = try Harness(refineEnabled: false)
    defer { off.tearDown() }
    off.monitor.onPressStart?()
    try await Task.sleep(for: .milliseconds(50))
    #expect(off.refiner.warmUpCount == 0)
}

@MainActor
@Test("Disabling dictation and turning the toggle off both shut the refiner down")
func shutdownPaths() async throws {
    let disabled = try Harness(refineEnabled: true)
    defer { disabled.tearDown() }
    disabled.controller.setEnabled(true)
    disabled.controller.setEnabled(false)
    #expect(disabled.refiner.shutdownCount >= 1)

    let toggledOff = try Harness(refineEnabled: true)
    defer { toggledOff.tearDown() }
    toggledOff.controller.refineEnabled = false
    #expect(toggledOff.refiner.shutdownCount >= 1)
}

@MainActor
@Test("Idle eviction shuts the refiner down alongside the whisper model")
func idleEvictionShutsRefinerDown() async throws {
    let harness = try Harness(refineEnabled: true, idleEvictSeconds: 0.05)
    defer { harness.tearDown() }
    try await harness.dictateOnce()
    // Delivery → dismiss (1.1 s) → idle-eviction timer (0.05 s) → refiner shutdown.
    for _ in 0..<300 where harness.refiner.shutdownCount == 0 {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(harness.refiner.shutdownCount >= 1)
}
