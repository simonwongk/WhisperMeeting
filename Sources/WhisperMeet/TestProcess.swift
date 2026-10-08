import Foundation

/// Whether this process is a test runner, and what it was refused (F442).
///
/// A test must never read the user's login Keychain or their `~/Library/Logs/DiagnosticReports`: the
/// first holds a real secret (the Claude API key) and may put up a Keychain prompt in a headless gate,
/// the second is real crash data about real applications, and either makes a test's result depend on
/// the host. Both were reachable by OMISSION: every `AppModel` a test built read the Keychain in its
/// `init`, and a second startup sweep on one defaults suite read the crash directory, because the
/// seams for them were assigned after construction and a test that did not assign them got the real
/// thing. About 190 constructions in 138 test files, so "every test must remember to stub it" was not
/// a rule anyone could keep.
///
/// So the real accessors check here and refuse, in a test process, to touch what they guard. They
/// answer "nothing there" (no key, no reports), which is what a stubbed seam answers, and record the
/// refusal so a test can say that it happened. A test that needs a key present, or a crash report,
/// says so through the seam (`ClaudeKeyStore.inMemory`, `AppModel.crashReportsSince`).
///
/// **Narrow on purpose.** A false positive here would stop the shipped app saving a Claude key, so the
/// signals are only ones a user's app launch cannot have: the SwiftPM test runner's or `xctest`'s own
/// executable name, or the variables XCTest sets. The app's executable is `WhisperMeet`.
enum TestProcess {
    static let isRunning: Bool = {
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "").lastPathComponent
        if executable == "swiftpm-testing-helper" || executable == "xctest" { return true }
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
    }()

    private static let lock = NSLock()
    private static var refusals: [String] = []

    /// What a real accessor declined to touch because it was asked from a test process.
    static var refusedAccesses: [String] { lock.withLock { refusals } }

    /// True when the caller may go ahead and touch the real resource. In a test process it is false,
    /// and the refusal is recorded under `what`.
    static func allowsRealAccess(to what: String) -> Bool {
        guard isRunning else { return true }
        lock.withLock { refusals.append(what) }
        return false
    }
}
