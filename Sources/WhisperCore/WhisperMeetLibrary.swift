import Foundation

/// Where the library is: `~/Library/Application Support/WhisperMeet`, or wherever
/// `WHISPERMEET_LIBRARY` says (F312).
///
/// One variable moves the whole library — index, dictation log, `Runtime/`, `Models/`, and since
/// F550 the settings (`defaults(environment:)`) — because they are one thing: a runtime installed
/// under one root and looked for under another is a broken install, not a relocated one. So this
/// is the single place a root is decided, and the four sites that used to each ask Foundation for
/// `.applicationSupportDirectory` ask this instead.
///
/// It exists for two reasons that turned out to be the same reason. `Scripts/rehearse-recovery.sh
/// --keep` ends with "point WhisperMeet at <dir>", and nothing could; and an on-screen check of a
/// recovery screen against a scratch library has no other way to keep the real library out of it —
/// Foundation resolves Application Support from the account, so even `HOME=<scratch>` opens the
/// user's real meetings, which on 2026-09-17 it did.
///
/// The value must be an absolute path. A relative one would put the library wherever the process
/// was launched from, which for a double-clicked app is `/`; blank is treated as unset.
public enum WhisperMeetLibrary {
    public static let environmentKey = "WHISPERMEET_LIBRARY"

    /// The library root for this process.
    public static func root(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let moved = movedRoot(environment: environment) { return moved }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("WhisperMeet", isDirectory: true)
    }

    /// The settings domain that belongs with `root` (F550): `.standard` for the ordinary library,
    /// and a suite of its own for a library moved by `WHISPERMEET_LIBRARY`.
    ///
    /// Moving the files alone was half a move. `UserDefaults.standard` is one domain per bundle id
    /// wherever the library is, and some of what the app keeps there is state ABOUT one library —
    /// the watched folder's known-files snapshot above all. A rehearsal instance sharing it would
    /// import a newly dropped file into the rehearsal library and record it as known, so the real
    /// library never imported it. Everything else follows the same rule rather than being sorted
    /// setting by setting, so a moved library starts from default settings and keeps its own.
    ///
    /// Only what is handed this value moves: `AppModel`'s and `DictationController`'s production
    /// initializers. `ContentView`'s two `@AppStorage` values (summary style and template) read
    /// `.standard` directly and are still shared.
    ///
    /// `openSuite` is for tests. A suite opened by this name is a plist in the user's real
    /// `~/Library/Preferences`, and `removePersistentDomain` empties that file without deleting it
    /// (F442), so a test that wrote through the real opener would leave one behind on every run.
    public static func defaults(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        openSuite: (String) -> UserDefaults? = { UserDefaults(suiteName: $0) }
    ) -> UserDefaults {
        guard let suiteName = defaultsSuiteName(environment: environment) else { return .standard }
        // `UserDefaults(suiteName:)` is nil only for the app's own bundle id and the global domain,
        // and this name is neither. Falling back to `.standard` here would quietly reintroduce the
        // shared state this exists to separate, so it is not a fallback worth having.
        guard let suite = openSuite(suiteName) else {
            preconditionFailure("UserDefaults refused the suite name \(suiteName)")
        }
        return suite
    }

    /// The suite `defaults` uses, or nil for the ordinary library. Derived from the root, so
    /// relaunching against the same directory finds the same settings, and two different
    /// directories get different suites. The suite is a plist in `~/Library/Preferences` named after
    /// this value.
    ///
    /// The root is keyed the way the writer lease keys its memo (`LibraryWriterLease`): symlinks
    /// resolved, then standardized. So two spellings of one existing directory, through a symlink
    /// or with a trailing slash, share one settings domain as they share one `.writer.lock`. A
    /// directory that does not exist yet has nothing to resolve and is keyed as spelled.
    /// `AppModel`'s convenience init asks only after its `MeetingStore` has created the root.
    public static func defaultsSuiteName(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let moved = movedRoot(environment: environment) else { return nil }
        // FNV-1a over the path's UTF-8: stable across launches and builds, which `hashValue` is
        // not (it is seeded per process).
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in moved.resolvingSymlinksInPath().standardizedFileURL.path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "WhisperMeet.library-" + String(format: "%016llx", hash)
    }

    /// The root `WHISPERMEET_LIBRARY` names, or nil when it is unset, blank or relative. One
    /// predicate, so the files and the settings can never disagree about whether the library moved.
    private static func movedRoot(environment: [String: String]) -> URL? {
        guard let value = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value, isDirectory: true)
    }
}
