import Darwin
import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

/// F486 — every warm helper takes its requests on a stdin pipe, and the only liveness check before a
/// write is `process.isRunning`. A helper that has died or closed its input after that check (an
/// MLX abort, a jetsam kill while holding a model) turns the write into SIGPIPE, whose default
/// action ends the whole app: the dictation, and any meeting being recorded with it. Foundation's
/// `Pipe` does not set `F_SETNOSIGPIPE`, and nothing ignored the signal.
///
/// Measured on this machine before the fix (a Swift program writing to a `Pipe` whose reader had
/// exited): exit status 141, i.e. killed by signal 13, with its own buffered output lost. Ignoring
/// the signal turns the same write into a thrown `NSPOSIXErrorDomain` 32 "Broken pipe". Foundation's
/// `Process` resets the child's SIGPIPE to the default (`SIG_DFL` observed in a spawned child while
/// the parent ignored it), as `ProcessGroupRunner` does with `POSIX_SPAWN_SETSIGDEF`, so ignoring it
/// here changes nothing for the helpers themselves.

/// Runs `body` with SIGPIPE at its default disposition — what a freshly launched app has — and puts
/// back whatever the test process had afterwards, so no other test inherits this one's setting.
private func withDefaultBrokenPipeDisposition(_ body: () async throws -> Void) async rethrows {
    let previous = signal(SIGPIPE, SIG_DFL)
    defer { signal(SIGPIPE, previous) }
    try await body()
}

@Test("A request to a helper that has stopped reading fails; it does not kill the app (F486)")
func writingToAClosedHelperThrowsInsteadOfKillingTheApp() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("BrokenPipeTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // Alive (so `isRunning` is true and no respawn happens) but no longer reading its input. The
    // input is closed BEFORE the ready line, so the request cannot land in the pipe first.
    let script = directory.appendingPathComponent("closed-input.sh")
    try """
    exec 0<&-
    printf '{"ready": true}\\n'
    exec sleep 30
    """.write(to: script, atomically: true, encoding: .utf8)
    let clip = directory.appendingPathComponent("clip.wav")
    try Data().write(to: clip)

    let engine = WarmWhisperDictationEngine(
        python: URL(fileURLWithPath: "/bin/sh"), script: script, modelDirectory: directory
    )
    defer { engine.shutdown() }

    try await withDefaultBrokenPipeDisposition {
        // What the app does first thing at launch.
        WhisperMeetLauncher.ignoreBrokenPipeSignals()
        try await engine.warmUp()
        await #expect(throws: (any Error).self) {
            _ = try await engine.transcribe(wavAt: clip, language: .automatic, initialPrompt: nil)
        }
    }
}

@Test("The app ignores SIGPIPE before it does anything else (F486)")
func launcherIgnoresBrokenPipesFirst() throws {
    let lines = try SourceAssertion.uncommentedLines("Sources/WhisperMeet/AppEntry.swift")
    let mainLine = try #require(
        lines.firstIndex { $0.text.contains("static func main()") },
        "WhisperMeetLauncher.main() was not found"
    )
    let firstStatement = lines[(mainLine + 1)...]
        .map { $0.text.trimmingCharacters(in: .whitespaces) }
        .first { !$0.isEmpty }
    // First, so no branch — the smoke tests included — can start a helper before it.
    #expect(firstStatement == "ignoreBrokenPipeSignals()")
}
