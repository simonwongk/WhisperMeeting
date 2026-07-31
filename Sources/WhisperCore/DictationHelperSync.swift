import Foundation

/// Keeps installed dictation-helper scripts in sync with the app bundle for **every** engine, not
/// just the currently selected one.
///
/// The bug this closes (F25): the app used to sync only the selected engine's helper on launch, so a
/// shipped helper fix (e.g. the F24 stdout-protocol fix) sat stale on disk for the *other* engine
/// until the user happened to switch to it — misleading every tool or diagnostic that reads the
/// installed runtime, and turning an already-shipped fix into something one user action away from
/// applying. Syncing all engines' helpers makes the installed runtime always reflect the running
/// build.
///
/// The installed runtime directory lives under a single shared
/// `~/Library/Application Support/WhisperMeet/` that any WhisperMeet process may touch, so this must
/// never assume it is the only writer:
///
/// * **Atomic writes.** Each helper is written with `.atomic` (write-to-temp-then-rename), so a
///   concurrent reader — the helper subprocess being spawned, a diagnostics read, or another syncing
///   process — never observes a half-written script.
/// * **Content-gated.** A helper whose on-disk bytes already equal the bundle is skipped, so repeated
///   or overlapping syncs converge on the bundle without redundant writes.
///
/// Pure and `Sendable`: it takes explicit inputs (bundle bytes, the on-disk path, whether that
/// engine's runtime is installed) and touches only the filesystem, so it is unit-testable against a
/// temporary directory without a GUI or the real install.
public enum DictationHelperSync {
    /// One engine's helper to reconcile against the bundle.
    public struct Helper: Sendable, Equatable {
        /// Diagnostic name (the bundled resource stem, e.g. `whisper_dictate_server`).
        public let name: String
        /// The bytes shipped in the app bundle, or `nil` if no bundled copy was found.
        public let bundledData: Data?
        /// Where the helper must land in the installed runtime.
        public let installedScript: URL
        /// Whether that engine's runtime is actually installed. An absent runtime is skipped, never
        /// created — there is nowhere to sync into yet.
        public let runtimeInstalled: Bool

        public init(name: String, bundledData: Data?, installedScript: URL, runtimeInstalled: Bool) {
            self.name = name
            self.bundledData = bundledData
            self.installedScript = installedScript
            self.runtimeInstalled = runtimeInstalled
        }
    }

    /// What happened to one helper, in the same order as the input, for the caller to log.
    public enum Outcome: Sendable, Equatable {
        /// Wrote the bundle copy over a missing or stale installed helper.
        case synced(String)
        /// The installed helper already matched the bundle; nothing written.
        case upToDate(String)
        /// That engine's runtime is not installed; there is nowhere to sync into.
        case runtimeAbsent(String)
        /// No bundled copy to sync from (a broken build).
        case bundleMissing(String)
        /// The write failed; carries the name and the error description.
        case failed(String, String)
    }

    /// Reconcile every supplied helper with its bundle copy. Returns one `Outcome` per input, in
    /// order. Only a helper whose runtime is installed *and* whose on-disk bytes differ from the
    /// bundle is written, and every write is atomic.
    @discardableResult
    public static func sync(
        _ helpers: [Helper],
        fileManager: FileManager = .default
    ) -> [Outcome] {
        helpers.map { helper in
            guard helper.runtimeInstalled else { return .runtimeAbsent(helper.name) }
            guard let bundledData = helper.bundledData else { return .bundleMissing(helper.name) }
            let installedData = try? Data(contentsOf: helper.installedScript)
            guard bundledData != installedData else { return .upToDate(helper.name) }
            do {
                try fileManager.createDirectory(
                    at: helper.installedScript.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try bundledData.write(to: helper.installedScript, options: .atomic)
                return .synced(helper.name)
            } catch {
                return .failed(helper.name, error.localizedDescription)
            }
        }
    }
}
