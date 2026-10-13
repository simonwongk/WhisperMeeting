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
/// signals are the SwiftPM test runner's or `xctest`'s own executable name, or the variables XCTest
/// sets — and a process running from an `.app` bundle is never one, whatever its environment says
/// (F882): `open` hands an app its caller's environment, XCTest's variables included, so a bundle
/// launched from a test's shell carried `XCTestBundlePath` and read as a test. The app's executable is
/// `WhisperMeet`, inside `WhisperMeet.app`; no test runner is a bundle.
enum TestProcess {
    static let isRunning: Bool = isTestProcess(
        executablePath: CommandLine.arguments.first ?? "",
        bundleURL: Bundle.main.bundleURL,
        environment: ProcessInfo.processInfo.environment
    )

    /// The classification `isRunning` is made from, over the process's facts so a test can give it
    /// another process's (F882).
    static func isTestProcess(executablePath: String, bundleURL: URL, environment: [String: String]) -> Bool {
        // First, and whatever the rest says: a process running from an `.app` bundle is the shipped
        // app (or a scratch copy of it), never a runner. Its environment is its launcher's, not its own.
        if bundleURL.pathExtension == "app" { return false }
        let executable = URL(fileURLWithPath: executablePath).lastPathComponent
        if executable == "swiftpm-testing-helper" || executable == "xctest" { return true }
        return environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
    }

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
