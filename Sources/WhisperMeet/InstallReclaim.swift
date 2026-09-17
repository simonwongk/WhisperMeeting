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

    static let qwen = InstallReclaim(
        artifactPrefix: ".Qwen3ASR",
        recoveryEnvironmentKey: "QWEN_INSTALL_RECOVERY_ONLY",
        scriptResource: "setup-qwen-asr"
    )
    static let summarizer = InstallReclaim(
        artifactPrefix: ".Summarizer",
        recoveryEnvironmentKey: "SUMMARIZER_INSTALL_RECOVERY_ONLY",
        scriptResource: "setup-local-summarizer"
    )
    static let diarization = InstallReclaim(
        artifactPrefix: ".Diarization",
        recoveryEnvironmentKey: "DIARIZATION_INSTALL_RECOVERY_ONLY",
        scriptResource: "setup-speaker-diarization"
    )

    /// A completed install's displaced predecessor.
    var backupPrefix: String { "\(artifactPrefix)-backup-" }
    /// An abandoned staging directory.
    var stagingPrefix: String { "\(artifactPrefix)-install-" }
}

extension AppModel {
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
        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [scriptURL.path, runtimeDirectory.path]
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
