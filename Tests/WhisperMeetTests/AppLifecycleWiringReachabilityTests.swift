import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F465 — F257's "window-independent" lifecycle was wired only from the WindowGroup ContentView's
// `.task`, which never runs at all if no window ever appears (a login item, or a window closed
// before the task ran). `AppLifecycleDelegate.applicationDidFinishLaunching` guards on
// `Self.lifecycle` being non-nil and returns early otherwise, so the "window-independent" path was
// dead code in exactly the launches it exists for: it always found the window's `.task` had not run
// yet.
//
// `WhisperMeetApp` is a SwiftUI `App`; this target has no view/scene-render harness (F174's standing
// reason — see AGENTS.md "Wiring an unreachable core"), so the only way to pin "this wiring no
// longer depends on the window's `.task` running" is to assert it against the source itself, with
// comments stripped first (F285's false positive: a paragraph merely *describing* the fix must not
// satisfy the check).
//
// The assertion is ordinal rather than brace-matched: everything F465 cares about must appear
// textually BEFORE `var body: some Scene {` — i.e. inside `init()`, which SwiftUI must finish
// constructing before the scene's `body` (and therefore the WindowGroup's `.task`) is ever asked
// for — and must not reappear inside the `.task` closure that follows it. `AppLifecycleTests.swift`
// already pins `AppLifecycle`'s own idempotence (begin()/runStartupRecoveryOnce() tolerate being
// called from both places); what was missing was any pin on WHERE the assignment that makes the
// delegate's path live actually happens.
@Test("The essential lifecycle wiring happens in WhisperMeetApp.init(), before `body` — not inside the window's .task (F465)")
func lifecycleWiringHappensBeforeBodyNotInsideTheWindowTask() throws {
    let source = SourceAssertion.stripComments(
        try String(contentsOf: SourceAssertion.url("Sources/WhisperMeet/AppEntry.swift"), encoding: .utf8)
    )

    let structKeyword = try #require(source.range(of: "struct WhisperMeetApp: App {"))
    let bodyKeyword = try #require(source.range(of: "var body: some Scene {"))
    let taskKeyword = try #require(source.range(of: ".task {"))
    #expect(bodyKeyword.lowerBound < taskKeyword.lowerBound, "sanity: body must contain the .task")

    let initRegion = source[structKeyword.upperBound..<bodyKeyword.lowerBound]
    let taskRegion = source[taskKeyword.upperBound...]

    // Every handler the delegate depends on, plus the assignment and begin() that make the delegate
    // path live, must be set up before `body` is ever computed — i.e. in `init()` — regardless of
    // whether any window's `.task` runs this launch.
    let requiredInInit = [
        "lifecycle.onFlush =",
        "lifecycle.onStartupRecovery =",
        "lifecycle.onOpenFiles =",
        "lifecycle.onRejectedFiles =",
        "AppLifecycleDelegate.lifecycle = lifecycle",
        "AppLifecycleDelegate.flushFilesOpenedBeforeLaunchFinished()",
        "lifecycle.begin()",
    ]
    for needle in requiredInInit {
        #expect(initRegion.contains(needle), "expected `\(needle)` in WhisperMeetApp.init(), before `body`")
        #expect(!taskRegion.contains(needle), "`\(needle)` must not depend on the window's .task running")
    }
}
