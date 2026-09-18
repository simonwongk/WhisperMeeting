import Foundation

/// Where the library is: `~/Library/Application Support/WhisperMeet`, or wherever
/// `WHISPERMEET_LIBRARY` says (F312).
///
/// One variable moves the whole library — index, dictation log, `Runtime/`, `Models/` — because
/// they are one thing: a runtime installed under one root and looked for under another is a
/// broken install, not a relocated one. So this is the single place a root is decided, and the
/// four sites that used to each ask Foundation for `.applicationSupportDirectory` ask this instead.
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
        if let value = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           value.hasPrefix("/") {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("WhisperMeet", isDirectory: true)
    }
}
