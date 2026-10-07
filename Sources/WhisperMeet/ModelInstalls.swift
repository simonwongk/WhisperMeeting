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
    /// Nil for the search-model download, which has never kept one.
    let logURL: URL?
    /// Seconds of silence after which the run is treated as stalled; 0 for none (F520). Only the
    /// search-model download has one: the other installers download silently for minutes at a time
    /// (setup-local-whisper.sh sends its model pre-download to /dev/null), and the user can now
    /// cancel them instead.
    var stallTimeout: TimeInterval = 0
}

/// How an install ended, decided by probing the disk afterwards — never by exit status alone
/// (F219's rule, which only speaker analysis followed before F567).
enum InstallOutcome: Equatable {
    case installed
    case failed(InstallerError)
    /// Cancelled from Settings or by Quit (F520) before the installer switched the new version in
    /// — from its switch-over on it ignores the signal, finishes and exits 0, and the run is judged
    /// like any finished install (F654). So the traps have put back what the run was replacing, and
    /// `previousKept` — installed before and still installed — is about the previous version.
    case cancelled(previousKept: Bool)
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
        // F823: Install / Repair Local Whisper moves the dictation model's folder aside, which made
        // a download in progress start again from zero. `.whisper`'s reason also gates the Qwen
        // button (`recognitionRuntimeInstallBlockedReason`), which only waits a little longer.
        if component == .whisper, isDictationModelDownloading() {
            return "Wait for the Quick Dictation model to finish downloading."
        }
        if isMicrophoneBusy { return "Wait for the current recording to finish." }
        if isImporting { return "Wait for the import to finish." }
        return nil
    }

    func canInstall(_ component: ModelInstallComponent) -> Bool {
        installBlockedReason(for: component) == nil
    }

    // MARK: - Cancellation (F520)

    /// Runs `body` as the install of `component`, holding its task so Cancel and Quit can stop it.
    ///
    /// Cancellation is the task's: every installer runs under `ProcessGroupRunner`, awaited
    /// directly (no detached task in between), so cancelling this task reaches the runner's
    /// cancellation handler, which sends SIGTERM to the installer's whole process group — pip,
    /// curl and Homebrew included. Until its switch-over, each script's `trap 'exit 130' HUP INT
    /// TERM` then runs its EXIT trap, which puts back the runtime it was replacing and removes what
    /// it staged (for Local Whisper, the Quick Dictation model's staging too). From the switch-over
    /// on there is nothing to put back, so each script ignores the signal, finishes and exits 0, and
    /// `runInstallerScript` reports that as the success it is (F654).
    ///
    /// It is also every install's epilogue, whatever `body` concluded — installed, failed or
    /// cancelled: `body` clears its own `isInstalling…` flag last, and then whatever transcription
    /// queued behind the install starts (F582).
    func launchInstall(_ component: ModelInstallComponent, _ body: @escaping @MainActor () async -> Void) {
        installTasks[component] = Task {
            await body()
            installTasks[component] = nil
            cancellingInstalls.remove(component)
            resumeTranscriptionQueueAfterInstall()
        }
    }

    /// Stops the install of `component`, if one is running. Before its switch-over the script puts
    /// back what it was replacing and the install reports itself cancelled; after it, the script
    /// finishes and the install reports itself installed (F654).
    func cancelInstall(_ component: ModelInstallComponent) {
        guard let task = installTasks[component] else { return }
        cancellingInstalls.insert(component)
        task.cancel()
    }

    /// Stops every running install — what Quit does (F520). Before this an install kept
    /// downloading headless after the app quit, on a metered link as readily as any, and the next
    /// launch's Install then failed on the script's lock ("Another … installation is already
    /// running"). While the installer is running, `Task.cancel()` runs the runner's cancellation
    /// handler synchronously on this thread, so the process group has its SIGTERM before
    /// `willTerminate` returns; an install cancelled before its script starts never spawns it.
    func cancelAllInstalls() {
        for component in installTasks.keys {
            cancelInstall(component)
        }
    }

    func isCancellingInstall(_ component: ModelInstallComponent) -> Bool {
        cancellingInstalls.contains(component)
    }

    /// The row message for a cancelled install.
    static func cancelledInstallMessage(previousKept: Bool) -> String {
        previousKept
            ? "Installation cancelled. The previous version was kept."
            : "Installation cancelled."
    }

    // MARK: - Running

    /// Runs one install and reports what the disk says afterwards (F567).
    ///
    /// `wasInstalled` is read before the run; "the previous version was kept" is claimed only when
    /// it was installed then AND is still installed now — a first install that fails has nothing to
    /// keep, which the Qwen, summarizer and speaker-analysis rows used to say it had.
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
        } catch is CancellationError {
            // Only a script that stopped before its switch-over gets here: one that got past it
            // exits 0 and returns above as a success (F654). (This used to also catch a cancel that
            // landed as a first install exited 0, because the runner threw regardless of the exit.)
            refreshRuntime()
            return .cancelled(previousKept: wasInstalled && isInstalled(self))
        } catch let error as InstallerError {
            refreshRuntime()
            return .failed(error.keepingPrevious(wasInstalled && isInstalled(self)))
        } catch {
            refreshRuntime()
            return .failed(.couldNotStart(component, reason: error.localizedDescription))
        }
    }

    /// Runs an installer script to completion under `ProcessGroupRunner` (F520), keeping its whole
    /// output in `job.logURL` and throwing an `InstallerError` whose reason is the output's last
    /// line (F567). Cancelling the calling task sends the script's process group SIGTERM. A script
    /// that then exits non-zero had not switched over, and this throws `CancellationError` once it
    /// has exited — after its traps have restored. One that exits 0 had passed its switch-over,
    /// where every installer ignores the signal and finishes (F654), and this returns normally.
    nonisolated static func runInstallerScript(_ job: InstallerJob) async throws {
        let log = try InstallerLog(url: job.logURL)
        defer { log.close() }
        let outcome: ProcessGroupRunner.Outcome
        do {
            outcome = try await ProcessGroupRunner().run(
                executableURL: URL(fileURLWithPath: "/bin/zsh"),
                arguments: [job.scriptURL.path] + job.arguments,
                environment: job.environment,
                stallTimeout: job.stallTimeout,
                returnsOutcomeWhenCancelled: true,
                onOutput: { log.write($0) }
            )
        } catch let error as ProcessGroupRunnerError {
            switch error {
            case .spawnFailed:
                throw InstallerError.couldNotStart(job.component, reason: error.localizedDescription)
            case .stalled:
                throw InstallerError.scriptFailed(job.component, reason: error.localizedDescription, previousKept: false)
            }
        }
        // F654: a cancelled installer that exited 0 had passed its switch-over, where every
        // installer ignores the signal and finishes — the new version is live, so this is success
        // and the caller probes it as one. Any other exit after a cancel is the cancel.
        if Task.isCancelled, outcome.exitStatus != 0 { throw CancellationError() }
        guard outcome.exitStatus == 0 else {
            throw InstallerError.scriptFailed(
                job.component,
                reason: InstallerOutput.failureReason(output: outcome.output, exitStatus: outcome.exitStatus),
                previousKept: false
            )
        }
    }
}

/// An installer's log file, appended to from `ProcessGroupRunner`'s reader queue.
private final class InstallerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?

    init(url: URL?) throws {
        guard let url else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: url, options: .atomic)
        handle = try FileHandle(forWritingTo: url)
    }

    func write(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.write(contentsOf: Data(text.utf8))
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }
}
