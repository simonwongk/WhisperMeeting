import Foundation

/// Which runtime a launch-time install reclaim is for (F285).
///
/// F33 (Qwen3-ASR), F219 (speaker analysis) and F167 (local summarizer) each added the same reclaim,
/// and the three were ~60 lines of identical code differing in two hidden-directory prefixes, an
/// environment-variable name and a bundled-script resource name. That is the shape which produced
/// F278's duplicated WAV header and F282's two manifest types, and two instances had already
/// appeared: the `-1` return ambiguous between "script missing" and "process would not start", in
/// all three; and no test anywhere for the property that makes a reclaim work — that recovery-only
/// mode skips the installer's preconditions.
///
/// Collapsed rather than left as a fourth copy waiting to be written. The three `reclaimInterrupted…`
/// entry points and their injected seams are unchanged, so the existing suites pass untouched —
/// which is F285's own verification: any of them needing an edit would mean the behaviour moved
/// rather than the duplication.
struct InstallReclaim: Sendable {
    /// The installer's hidden-directory stem, e.g. `.Qwen3ASR`.
    let artifactPrefix: String
    /// The environment variable that puts the installer into reclaim-and-exit mode.
    let recoveryEnvironmentKey: String
    /// The bundled script's resource name, without its `.sh` extension.
    let scriptResource: String
    /// The runtime's directory name under `Runtime/` (F655) — the name each WhisperCore runtime
    /// type appends to `LocalWhisperRuntime.managedDirectory`; `StartupReclaimScopeTests` pins the
    /// two together.
    let runtimeName: String
    /// Whether the script takes the runtime's PARENT directory as its argument rather than the
    /// runtime itself (F520). Local Whisper's installer takes `Runtime/` and keeps its venv at
    /// `Runtime/venv`; the other three take their own `Runtime/<Name>` target. The artifacts are
    /// siblings of the runtime either way, so the scan is the same.
    var scriptTakesParentDirectory = false

    /// The meetings-critical default runtime, the one F33/F219/F167 never covered (F520). Its
    /// runtime is `Runtime/venv`, so its artifacts are `Runtime/.venv-backup-*` and
    /// `Runtime/.venv-install-*`; the `.venv-install.lock` beside them does not match either prefix.
    static let whisper = InstallReclaim(
        artifactPrefix: ".venv",
        recoveryEnvironmentKey: "WHISPER_INSTALL_RECOVERY_ONLY",
        scriptResource: "setup-local-whisper",
        runtimeName: "venv",
        scriptTakesParentDirectory: true
    )
    static let qwen = InstallReclaim(
        artifactPrefix: ".Qwen3ASR",
        recoveryEnvironmentKey: "QWEN_INSTALL_RECOVERY_ONLY",
        scriptResource: "setup-qwen-asr",
        runtimeName: "Qwen3ASR"
    )
    static let summarizer = InstallReclaim(
        artifactPrefix: ".Summarizer",
        recoveryEnvironmentKey: "SUMMARIZER_INSTALL_RECOVERY_ONLY",
        scriptResource: "setup-local-summarizer",
        runtimeName: "Summarizer"
    )
    static let diarization = InstallReclaim(
        artifactPrefix: ".Diarization",
        recoveryEnvironmentKey: "DIARIZATION_INSTALL_RECOVERY_ONLY",
        scriptResource: "setup-speaker-diarization",
        runtimeName: "Diarization"
    )

    /// Every runtime the launch reclaims (F655), in the order `performStartupRecovery` runs them.
    static let all: [InstallReclaim] = [.whisper, .qwen, .diarization, .summarizer]

    /// What the recovery run is given on its command line for the runtime at `runtimeDirectory`.
    func scriptArgument(for runtimeDirectory: URL) -> URL {
        scriptTakesParentDirectory ? runtimeDirectory.deletingLastPathComponent() : runtimeDirectory
    }

    /// A completed install's displaced predecessor.
    var backupPrefix: String { "\(artifactPrefix)-backup-" }
    /// An abandoned staging directory.
    var stagingPrefix: String { "\(artifactPrefix)-install-" }
}

extension AppModel {
    /// The `Runtime/` of the library this model was opened on (F655). In the app that is the managed
    /// runtime — `MeetingStore()` opens `WhisperMeetLibrary.root()`, which is where
    /// `LocalWhisperRuntime.managedDirectory()` lives — and in a test it is the test's own temp
    /// library, so no launch reclaim a test runs can reach the user's real runtime.
    var libraryRuntimeDirectory: URL {
        store.rootDirectory.appendingPathComponent("Runtime", isDirectory: true)
    }

    /// Where `reclaim`'s runtime lives in this model's library (F655).
    func runtimeDirectory(for reclaim: InstallReclaim) -> URL {
        libraryRuntimeDirectory.appendingPathComponent(reclaim.runtimeName, isDirectory: true)
    }

    /// True when the runtime parent holds installer-owned orphan artifacts for `reclaim` (F285).
    ///
    /// Only the installer's own hidden names match, so this never fires on a clean runtime — the
    /// live `Qwen3ASR/`, `Summarizer/` and `Diarization/` carry none of these prefixes, nor does
    /// `.Diarization-install.lock`, whose staleness `shlock` already settles. An unlistable parent
    /// reports false: a Mac that never installed the runtime has no parent directory, and that is
    /// the common case rather than an error.
    nonisolated static func hasOrphanedInstallArtifacts(
        in parent: URL,
        for reclaim: InstallReclaim
    ) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else {
            return false
        }
        return entries.contains {
            $0.hasPrefix(reclaim.backupPrefix) || $0.hasPrefix(reclaim.stagingPrefix)
        }
    }

    /// Spawns the bundled installer in recovery-only mode and returns its exit status (F285).
    ///
    /// **All three now take the development-script fallback**, which only the speaker-analysis copy
    /// had. That is a deliberate behaviour change and an improvement: a build running without
    /// bundled resources could not previously reclaim a Qwen or summarizer install, and the reason
    /// was that the fallback was added to one copy and never propagated — this ticket's whole
    /// subject.
    ///
    /// Returns `-1` when the script cannot be found or the process will not start. That ambiguity
    /// is carried over from all three originals rather than fixed here, because the callers ignore
    /// the value and telling them apart would need a real error type.
    nonisolated static func spawnInstallRecovery(
        runtimeDirectory: URL,
        for reclaim: InstallReclaim
    ) async -> Int32 {
        guard let scriptURL = Bundle.main.url(
            forResource: reclaim.scriptResource,
            withExtension: "sh"
        ) ?? developmentScriptURL("\(reclaim.scriptResource).sh") else {
            return -1
        }
        let argument = reclaim.scriptArgument(for: runtimeDirectory)
        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [scriptURL.path, argument.path]
            var environment = ProcessInfo.processInfo.environment
            environment[reclaim.recoveryEnvironmentKey] = "1"
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus
            } catch {
                return -1
            }
        }.value
    }
}

// MARK: - Interrupted Local Whisper install reclaim (F520 — the fourth reclaim)

extension AppModel {
    /// Reclaims an interrupted Local Whisper install at launch, only when installer-owned orphans
    /// exist beside the venv — so a clean launch, or a Mac using a Homebrew `whisper`, spawns
    /// nothing. Returns whether the reclaim ran.
    ///
    /// A battery that dies during "Repair or Update", or a force quit, can leave the only working
    /// venv in `Runtime/.venv-backup-<pid>` with `Runtime/venv` gone, or a multi-GB staging venv
    /// behind. Qwen, speaker analysis and the summarizer have reclaimed exactly this at launch since
    /// F33/F219/F167; the meetings-critical runtime did not, and showed "Whisper not installed" (or
    /// a stale Homebrew fallback) until the user happened to reinstall.
    ///
    /// **Starts from the venv, not from `Runtime/`.** The artifacts are the venv's siblings, so the
    /// scan is in the venv's parent — `Runtime/`. Handing this `Runtime/` would scan the library
    /// root instead and never find anything. The script itself takes `Runtime/`
    /// (`InstallReclaim.whisper.scriptArgument(for:)`).
    ///
    /// `venvDirectory` defaults to `whisperVenvDirectory` (a default argument cannot read an
    /// instance property, hence the optional).
    @discardableResult
    func reclaimInterruptedWhisperInstall(venvDirectory: URL? = nil) async -> Bool {
        let venv = venvDirectory ?? whisperVenvDirectory
        guard Self.hasOrphanedInstallArtifacts(in: venv.deletingLastPathComponent(), for: .whisper) else {
            return false
        }
        _ = await runWhisperInstallRecovery(venv)
        return true
    }
}
