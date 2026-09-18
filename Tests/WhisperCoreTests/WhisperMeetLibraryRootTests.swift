import Foundation
import Testing
@testable import WhisperCore

// F312 — one place decides where the library is, and one variable can move it.
//
// Every root used to be derived independently from `.applicationSupportDirectory`, which Foundation
// resolves from the account rather than `$HOME` — so nothing short of a different user could run
// the app against a different library, and `rehearse-recovery.sh --keep` told the user to do
// something impossible. Injected environments here, never `setenv`: the suite runs in one process.

@Test("Without the variable, the library is under Application Support as it always was (F312)")
func defaultLibraryRootIsApplicationSupport() {
    let root = WhisperMeetLibrary.root(environment: [:])
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    #expect(root == support.appendingPathComponent("WhisperMeet", isDirectory: true))
}

@Test("WHISPERMEET_LIBRARY moves the whole library, runtime and models included (F312)")
func variableMovesEveryRoot() {
    let scratch = "/tmp/whispermeet-scratch-\(UUID().uuidString)"
    let environment = [WhisperMeetLibrary.environmentKey: scratch]

    #expect(WhisperMeetLibrary.root(environment: environment).path == scratch)
    // The runtimes funnel through these two; a library that moved without its runtime would
    // install helpers into one place and look for them in another.
    #expect(LocalWhisperRuntime.managedDirectory(environment: environment).path == "\(scratch)/Runtime")
    #expect(LocalWhisperRuntime.modelDirectory(environment: environment).path == "\(scratch)/Models")
}

@Test("A blank or relative value is ignored rather than resolved against the working directory (F312)")
func blankOrRelativeValueIsIgnored() {
    let support = WhisperMeetLibrary.root(environment: [:])
    #expect(WhisperMeetLibrary.root(environment: [WhisperMeetLibrary.environmentKey: ""]) == support)
    #expect(WhisperMeetLibrary.root(environment: [WhisperMeetLibrary.environmentKey: "   "]) == support)
    // A relative path would put the library wherever the app happened to be launched from, which
    // for a double-clicked app is `/`.
    #expect(WhisperMeetLibrary.root(environment: [WhisperMeetLibrary.environmentKey: "scratch/lib"]) == support)
}

@Test("An explicit applicationSupport argument still wins over the variable (F312)")
func explicitArgumentWins() {
    // The injected-parameter seam every runtime already has is for tests and installers that
    // know exactly where they are working; the variable is for a whole process. The narrower one
    // must not be silently overridden by the wider one.
    let explicit = URL(fileURLWithPath: "/tmp/explicit-support-\(UUID().uuidString)")
    let environment = [WhisperMeetLibrary.environmentKey: "/tmp/should-lose"]
    #expect(
        LocalWhisperRuntime.managedDirectory(applicationSupport: explicit, environment: environment)
            == explicit.appendingPathComponent("WhisperMeet", isDirectory: true)
                .appendingPathComponent("Runtime", isDirectory: true)
    )
}
