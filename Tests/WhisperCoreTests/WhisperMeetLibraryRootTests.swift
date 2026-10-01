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

// F550 — the variable moved every file and none of the settings. `UserDefaults.standard` is one
// domain for the bundle id wherever the library is, so a rehearsal instance read and wrote the real
// library's watched-folder snapshot, dictation hotkey and last-launch stamp. A moved library gets a
// settings domain of its own, derived from its root.
//
// Nothing here writes a setting at all. `.standard` is the user's real domain, and a suite opened
// by its derived name is a plist in the user's real ~/Library/Preferences that
// `removePersistentDomain` empties but never deletes (F442): the first version of the test below
// left one there on every run. What `defaults` returns is checked by identity instead, through the
// `openSuite` seam.

@Test("Without the variable, settings stay in the standard domain (F550)")
func defaultLibraryUsesStandardDefaults() {
    #expect(WhisperMeetLibrary.defaultsSuiteName(environment: [:]) == nil)
    #expect(WhisperMeetLibrary.defaults(environment: [:]) === UserDefaults.standard)
    // Ignored exactly where `root` ignores it, so settings and files can never disagree about
    // which library this is.
    #expect(WhisperMeetLibrary.defaultsSuiteName(environment: [WhisperMeetLibrary.environmentKey: "  "]) == nil)
    #expect(WhisperMeetLibrary.defaultsSuiteName(environment: [WhisperMeetLibrary.environmentKey: "scratch/lib"]) == nil)
}

@Test("A moved library gets its own settings domain, the same one on every launch (F550)")
func movedLibraryGetsADomainDerivedFromItsRoot() throws {
    let a = "/tmp/whispermeet-rehearsal-\(UUID().uuidString)"
    let b = "/tmp/whispermeet-rehearsal-\(UUID().uuidString)"
    let nameA = try #require(WhisperMeetLibrary.defaultsSuiteName(environment: [WhisperMeetLibrary.environmentKey: a]))
    let nameB = try #require(WhisperMeetLibrary.defaultsSuiteName(environment: [WhisperMeetLibrary.environmentKey: b]))

    #expect(nameA != nameB)
    // Derived, not random: relaunching against the same rehearsal must find its own settings.
    #expect(WhisperMeetLibrary.defaultsSuiteName(environment: [WhisperMeetLibrary.environmentKey: a]) == nameA)
    // The same directory spelled with a trailing slash is the same library.
    #expect(WhisperMeetLibrary.defaultsSuiteName(environment: [WhisperMeetLibrary.environmentKey: a + "/"]) == nameA)

    // `defaults` opens exactly the suite `defaultsSuiteName` names, and hands back what it opened.
    // The opener returns a suite named by a path under the temp directory, which is never written,
    // so not even that file exists.
    var opened: [(name: String, suite: UserDefaults)] = []
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("F550-\(UUID().uuidString)")
    func open(_ name: String) -> UserDefaults? {
        let suite = UserDefaults(suiteName: scratch.appendingPathComponent(name).path)
        if let suite { opened.append((name, suite)) }
        return suite
    }
    let defaultsA = WhisperMeetLibrary.defaults(environment: [WhisperMeetLibrary.environmentKey: a], openSuite: open)
    let defaultsB = WhisperMeetLibrary.defaults(environment: [WhisperMeetLibrary.environmentKey: b], openSuite: open)
    try #require(opened.count == 2, "\(opened.map(\.name))")
    #expect(opened.map(\.name) == [nameA, nameB])
    #expect(defaultsA === opened[0].suite)
    #expect(defaultsB === opened[1].suite)
    // And the real opener does not quietly return the user's own domain. Opening a suite writes
    // nothing; only setting a value would.
    #expect(WhisperMeetLibrary.defaults(environment: [WhisperMeetLibrary.environmentKey: a]) !== UserDefaults.standard)
}
