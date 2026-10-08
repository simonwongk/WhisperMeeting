import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F442 — tests must not touch the user's real environment: leaked UserDefaults suites in
// ~/Library/Preferences (Part 1), the login Keychain's Claude key (Parts 2 and 3) and
// ~/Library/Logs/DiagnosticReports (Part 4). Each guard here fails if a test reaches one of them.

// MARK: - Part 1: UserDefaults suites

@Test("A test suite name is bounded and starts empty, so a run reuses last run's files instead of adding new ones (F442)")
func testSuiteNamesAreBoundedAndStartEmpty() throws {
    let first = testSuiteName()
    let second = testSuiteName()
    #expect(first != second, "two suites built in one run must not share a name")

    // WhisperMeetTests.s<slot>.n<count>: no UUID, so nothing new appears in ~/Library/Preferences per run.
    for name in [first, second] {
        #expect(name.range(of: #"^WhisperMeetTests\.s[0-9]+\.n[0-9]+$"#, options: .regularExpression) != nil, "\(name)")
    }

    // A later run reuses names, and must find them empty: leave something in the name the NEXT call
    // will hand out, as an earlier run's test would have, and require that call to clear it.
    let count = try #require(Int(second.components(separatedBy: ".n").last ?? ""))
    let slotPrefix = String(second.dropLast(String(count).count))
    let upcoming = "\(slotPrefix)\(count + 1)"
    let leftBehind = try #require(UserDefaults(suiteName: upcoming))
    leftBehind.set("left by an earlier run", forKey: "leftover")
    try #require(leftBehind.string(forKey: "leftover") != nil)

    let handedOut = testSuiteName()
    try #require(handedOut == upcoming, "the counter is not what this test assumes")
    #expect(UserDefaults(suiteName: handedOut)?.string(forKey: "leftover") == nil,
            "a name reused from an earlier run still held its old contents")
    UserDefaults(suiteName: handedOut)?.removePersistentDomain(forName: handedOut)
}

@Test("No test names a UserDefaults suite with a UUID (F442)")
func noTestSuiteNameCarriesAUUID() throws {
    // `removePersistentDomain` empties a suite but leaves a 42-byte plist, so a UUID-suffixed name leaves
    // one file in the user's real ~/Library/Preferences per suite per run: 42,252 of them by 2026-09-24.
    // A source scan, comments stripped (F285), because the leak is made by the text of the test.
    var offenders: [String] = []
    for directory in ["Tests/WhisperMeetTests", "Tests/WhisperCoreTests"] {
        for url in try SourceAssertion.swiftFileURLs(under: directory) {
            guard url.lastPathComponent != "TestEnvironmentGuardTests.swift" else { continue }
            let text = SourceAssertion.stripComments(try String(contentsOf: url, encoding: .utf8))
            let lines = SourceAssertion.numbered(text)
            // Names a suite is built from: any identifier handed to `UserDefaults(suiteName:)`.
            var suiteVariables: Set<String> = []
            for (_, line) in lines {
                guard let call = line.range(of: #"UserDefaults\(\s*suiteName:\s*"#, options: .regularExpression) else { continue }
                let argument = line[call.upperBound...]
                // A suite named by a PATH keeps its plist at that path, inside the test's own scratch
                // directory, and never in ~/Library/Preferences: not this leak.
                if argument.contains(".path") || argument.contains("appendingPathComponent") { continue }
                if let identifier = argument.range(of: #"^[A-Za-z_][A-Za-z0-9_]*"#, options: .regularExpression) {
                    suiteVariables.insert(String(argument[identifier]))
                }
            }
            for (number, line) in lines {
                let lowered = line.lowercased()
                guard lowered.contains("uuid") else { continue }
                let aboutASuite = lowered.contains("suite")
                    || suiteVariables.contains { line.range(of: #"\b(let|var)\s+\#($0)\b"#, options: .regularExpression) != nil }
                if aboutASuite {
                    offenders.append("\(url.lastPathComponent):\(number): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
    }
    #expect(offenders.isEmpty, """
        a test names a UserDefaults suite with a UUID, which leaves a new plist in ~/Library/Preferences on \
        every run. Use `testSuiteName()` (Tests/WhisperMeetTests/TestDefaultsSupport.swift):
        \(offenders.joined(separator: "\n"))
        """)
}

// MARK: - Parts 2 to 4: the Keychain and the crash directory

@Test("The test runner is recognised as one, which is what the other guards rest on (F442)")
func theTestProcessIsRecognised() {
    // If this stopped being true, `KeychainStore` and the crash-report default would quietly start
    // touching the real things again and nothing else here would say so.
    #expect(TestProcess.isRunning)
}

@MainActor
@Test("A model built without a key store does not read the login Keychain (F442)")
func aDefaultModelNeverReadsTheRealKeychain() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F442-keychain-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = try #require(UserDefaults(suiteName: testSuiteName()))

    let before = TestProcess.refusedAccesses.count
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)

    // `init` asked the Keychain whether a key exists (that is production behaviour) and was refused.
    // Had it been answered, `hasClaudeAPIKey` would depend on this Mac's login keychain.
    #expect(TestProcess.refusedAccesses.count == before + 1)
    #expect(TestProcess.refusedAccesses.last == "Keychain read")
    #expect(!model.hasClaudeAPIKey)

    // Saving and clearing a key go the same way: refused, and nothing is written for the next test.
    model.setClaudeAPIKey("sk-ant-not-a-real-key")
    #expect(!model.hasClaudeAPIKey, "a key written in a test reached a store the next test can read")
}

@MainActor
@Test("A key store handed to the model replaces the Keychain for reading, writing and clearing (F442)")
func theModelUsesTheKeyStoreItWasGiven() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F442-keystore-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = try #require(UserDefaults(suiteName: testSuiteName()))
    let refusedBefore = TestProcess.refusedAccesses.count

    let model = AppModel(
        store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults,
        claudeKeyStore: .inMemory("sk-ant-fixture")
    )
    #expect(model.hasClaudeAPIKey)
    #expect(model.claudeKeyStore.read() == "sk-ant-fixture")

    model.setClaudeAPIKey("  sk-ant-replaced \n")
    #expect(model.claudeKeyStore.read() == "sk-ant-replaced", "the key is stored trimmed, as the Keychain wrapper stores it")
    model.setClaudeAPIKey("   ")
    #expect(!model.hasClaudeAPIKey)
    #expect(model.claudeKeyStore.read() == nil)

    #expect(TestProcess.refusedAccesses.count == refusedBefore, "a model with its own store still asked the real Keychain")
}

@MainActor
@Test("A second startup sweep without an injected crash reader does not read ~/Library/Logs/DiagnosticReports (F442)")
func theCrashSweepNeverReadsTheRealDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F442-crash-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = try #require(UserDefaults(suiteName: testSuiteName()))
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)

    // The first sweep finds no launch stamp and reports nothing without reading; it writes the stamp.
    // The second is the one that used to read the real directory (`InterruptedLinkImportTests`).
    #expect(model.crashReportsSinceLastLaunch().isEmpty)
    let before = TestProcess.refusedAccesses.count
    #expect(model.crashReportsSinceLastLaunch().isEmpty)

    #expect(TestProcess.refusedAccesses.count == before + 1)
    #expect(TestProcess.refusedAccesses.last == "DiagnosticReports")
}

@Test("No test calls the Keychain wrapper directly (F442)")
func noTestCallsKeychainStore() throws {
    // The wrapper refuses in a test process, so a call is harmless, but it is also pointless and it is
    // the shape of the original leak: a test that "just checks" what is saved reads the user's secret.
    // A test that needs a key uses `ClaudeKeyStore.inMemory`.
    var offenders: [String] = []
    for url in try SourceAssertion.swiftFileURLs(under: "Tests/WhisperMeetTests") {
        guard url.lastPathComponent != "TestEnvironmentGuardTests.swift" else { continue }
        let text = SourceAssertion.stripComments(try String(contentsOf: url, encoding: .utf8))
        for (number, line) in SourceAssertion.numbered(text) where line.contains("KeychainStore.") {
            offenders.append("\(url.lastPathComponent):\(number): \(line.trimmingCharacters(in: .whitespaces))")
        }
    }
    #expect(offenders.isEmpty, "a test reaches the Keychain wrapper:\n\(offenders.joined(separator: "\n"))")
}
