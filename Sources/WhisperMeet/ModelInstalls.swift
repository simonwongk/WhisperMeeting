import Foundation
import WhisperCore

/// One run of a bundled installer script (F567).
struct InstallerJob: Sendable {
    let component: ModelInstallComponent
    let scriptURL: URL
    /// What follows the script path on the command line — each installer takes its runtime
    /// directory.
    let arguments: [String]
    var environment: [String: String] = ProcessInfo.processInfo.environment
    /// Where the full output goes. The alert carries one line; this keeps the rest for diagnosis.
    let logURL: URL
}

/// How an install ended, decided by probing the disk afterwards — never by exit status alone
/// (F219's rule, which only speaker analysis followed before F567).
enum InstallOutcome: Equatable {
    case installed
    case failed(InstallerError)
}

extension AppModel {
    /// Why an install of `component` cannot start now, or nil when it can (F567).
    ///
    /// The one admission check: each installer's guard asks it, and so does the button that starts
    /// it. Before this, the guards and the Settings buttons were separate hand-written lists that
    /// had drifted — the summarizer's button ignored a running second opinion, and the
    /// speaker-analysis button ignored a running summarizer or search-model install — so a press
    /// the model refused did nothing, with no progress and no message. F514 fixed the same shape
    /// for Whisper and Qwen with `recognitionRuntimeInstallBlockedReason`, which is now this
    /// function for `.whisper`.
    ///
    /// Every installer's guard already refused on exactly these conditions (the speaker-analysis
    /// line is implied by the auxiliary-run one, and only sharpens the reason); what F567 changes is
    /// that the buttons now ask the same thing. Ask's search model is the exception it always was:
    /// it replaces no runtime a transcription, analysis or dictation runs from, so another install
    /// is its only conflict (F440) — and its own guard and button still ask `isInstallingAnyRuntime`
    /// directly, which is this answer for `.askEmbeddings`.
    func installBlockedReason(for component: ModelInstallComponent) -> String? {
        if isInstallingAnyRuntime { return "Another install is already running." }
        if component == .askEmbeddings { return nil }
        if hasActiveTranscription { return "Wait for the current transcription to finish." }
        // Before the general auxiliary-run line, which speaker analysis also holds, so the reason
        // names what is actually running.
        if diarizationRunningID != nil { return "Wait for speaker analysis to finish." }
        if isRunningAuxiliaryEngine { return "Wait for the second opinion or segment re-run to finish." }
        if isDictationActive() { return "Wait for Quick Dictation to finish." }
        if isMicrophoneBusy { return "Wait for the current recording to finish." }
        if isImporting { return "Wait for the import to finish." }
        return nil
    }

    func canInstall(_ component: ModelInstallComponent) -> Bool {
        installBlockedReason(for: component) == nil
    }

    /// Runs one install and reports what the disk says afterwards (F567).
    ///
    /// `wasInstalled` is read before the run; "the previous version was kept" is claimed only when
    /// it was installed then AND is still installed now — a first install that fails has nothing to
    /// keep, which every row used to say it had.
    func performInstall(
        _ component: ModelInstallComponent,
        wasInstalled: Bool,
        isInstalled: @MainActor (AppModel) -> Bool,
        operation: @Sendable () async throws -> Void
    ) async -> InstallOutcome {
        do {
            try await operation()
            refreshRuntime()
            return isInstalled(self) ? .installed : .failed(.notReady(component))
        } catch let error as InstallerError {
            refreshRuntime()
            return .failed(error.keepingPrevious(wasInstalled && isInstalled(self)))
        } catch {
            refreshRuntime()
            return .failed(.couldNotStart(component, reason: error.localizedDescription))
        }
    }

    /// Runs an installer script to completion, keeping its whole output in `job.logURL` and
    /// throwing an `InstallerError` whose reason is the output's last line (F567).
    nonisolated static func runInstallerScript(_ job: InstallerJob) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(
                at: job.logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: job.logURL, options: .atomic)
            let handle = try FileHandle(forWritingTo: job.logURL)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [job.scriptURL.path] + job.arguments
            process.environment = job.environment
            process.standardOutput = handle
            process.standardError = handle
            do {
                try process.run()
            } catch {
                try? handle.close()
                throw InstallerError.couldNotStart(job.component, reason: error.localizedDescription)
            }
            process.waitUntilExit()
            try? handle.close()
            guard process.terminationStatus == 0 else {
                let log = (try? String(contentsOf: job.logURL, encoding: .utf8)) ?? ""
                throw InstallerError.scriptFailed(
                    job.component,
                    reason: InstallerOutput.failureReason(output: log, exitStatus: process.terminationStatus),
                    previousKept: false
                )
            }
        }.value
    }
}
