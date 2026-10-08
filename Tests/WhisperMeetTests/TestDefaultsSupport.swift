import Darwin
import Foundation

// F442 part 1 — a name for a test's UserDefaults suite that does not leave a new file behind on every run.
//
// `UserDefaults(suiteName: "<Prefix>.\(UUID().uuidString)")` creates a persistent domain, and so a
// plist under the user's real ~/Library/Preferences, named for that UUID. `removePersistentDomain`
// empties the domain but leaves a 42-byte file, so every run added one file per suite built: 42,252 of
// them by 2026-09-24 and about 139,700 by 2026-10-07. Nothing ever reads them again.
//
// The name is now bounded instead of unique. `testSuiteName()` returns `WhisperMeetTests.s<slot>.n<count>`:
//
// - `count` is this process's nth request, so two suites built in one run never share a name, and a
//   run reuses the same names the last run did, however many suites it builds;
// - `slot` is the lowest of 16 per-user slots no other live test process holds, claimed once with an
//   `flock` that the kernel releases when the process ends. Two test processes at the same time (two
//   worktrees, or a gate beside an agent) would otherwise clear each other's live suites;
// - the domain is emptied before the name is handed out, so a name reused from an earlier run starts
//   empty and a test cannot see what an earlier test left in it.
//
// The files that remain are bounded by 16 slots times the most suites one run builds, and are rewritten
// in place. `testSuiteNamesAreBoundedAndStartEmpty` and `noTestSuiteNameCarriesAUUID`
// (TestEnvironmentGuardTests.swift) check the name's shape and keep the UUID form from coming back.

private enum SuiteSlot {
    static let slots = 16
    /// The lowest slot no other live process holds, with the descriptor kept open for the life of
    /// the process (closing it would release the claim). Slot `slots` means "none free": two
    /// processes may then share names, which is the pre-existing risk and not a new one.
    static let claimed: Int = {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperMeetTests-suite-slots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for slot in 0..<slots {
            let descriptor = open(directory.appendingPathComponent("slot-\(slot).lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else { continue }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return slot } // deliberately not closed
            close(descriptor)
        }
        return slots
    }()
    private static let lock = NSLock()
    private static var count = 0
    static func next() -> Int {
        lock.withLock { count += 1; return count }
    }
}

/// A suite name that is empty and used by nobody else right now. Replaces
/// `"<Prefix>.\(UUID().uuidString)"` everywhere a test builds a `UserDefaults` suite (F442).
func testSuiteName() -> String {
    let name = "WhisperMeetTests.s\(SuiteSlot.claimed).n\(SuiteSlot.next())"
    UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
    return name
}
