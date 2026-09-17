import SwiftUI
import AppKit
import WhisperCore

struct DictationView: View {
    @ObservedObject var dictation: DictationController
    @ObservedObject var log: DictationLogStore
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var diag = DictationDiagnostics(
        engineName: "", runtimeInstalled: false, helperInstalled: false, modelReady: false,
        microphoneGranted: false, accessibilityGranted: false, hotkeyActive: false
    )

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quick Dictation").font(.largeTitle.bold())
                    Text("Hold \(DictationKeyName.display(for: dictation.hotkey.keyCode)) anywhere, speak, release — the transcript is pasted into the focused field (or copied). 100% local.")
                        .foregroundStyle(.secondary)
                    // F195: BEFORE the hotkey instruction is acted on, not under the History
                    // heading below. The read-only banner used to live there, so a user held the
                    // key, spoke, and learned afterwards that nothing had been kept. Placed right
                    // beneath the sentence telling them to hold the key, because that is the
                    // instruction it qualifies.
                    if let warning = log.preDictationWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .bannerSurface(.orange)
                            .accessibilityElement(children: .combine)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Label("Status & diagnostics", systemImage: "stethoscope")
                        .font(.headline)
                    VStack(alignment: .leading, spacing: 10) {
                        statusRow("\(diag.engineName) runtime", diag.runtimeInstalled)
                        statusRow("Dictation helper installed", diag.helperInstalled)
                        statusRow("Selected model ready", diag.modelReady)
                        statusRow("Microphone permission", diag.microphoneGranted)
                        statusRow("Accessibility permission", diag.accessibilityGranted)
                        statusRow("Hotkey listening", diag.hotkeyActive)
                        Divider()
                        HStack {
                            Button { dictation.runSelfTest() } label: {
                                if dictation.isSelfTesting { ProgressView().controlSize(.small) }
                                else { Text("Run self-test") }
                            }
                            .disabled(dictation.isSelfTesting)
                            Button("Refresh") { diag = dictation.diagnostics() }
                            if !diag.runtimeInstalled || !diag.helperInstalled || !diag.modelReady {
                                if dictation.selectedEngine == .qwenBalanced {
                                    Button("Install / Repair Qwen3-ASR") { model.installQwenASR() }
                                        .disabled(model.isInstallingQwenRuntime)
                                } else {
                                    Button("Install / Repair Local Whisper") { model.installLocalWhisper() }
                                        .disabled(model.isInstallingRuntime)
                                }
                            }
                            Spacer()
                        }
                        if let result = dictation.selfTestResult {
                            // The multi-second self-test payoff fades in instead of snapping the
                            // layout (F161, the F116 vocabulary).
                            Text(result)
                                .font(.callout)
                                .foregroundStyle(result.hasPrefix("✓") ? .green : .orange)
                                .textSelection(.enabled)
                                .transition(.gentleFade(reduceMotion: reduceMotion))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Scoped so only the self-test result's arrival animates (F161).
                    .animation(reduceMotion ? nil : .uiSpring, value: dictation.selfTestResult)
                }
                .padding(16)
                .cardSurface()
                .onChange(of: dictation.isSelfTesting) { _, testing in if !testing { diag = dictation.diagnostics() } }

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Label("History", systemImage: "clock.arrow.circlepath")
                            .font(.headline)
                        Spacer()
                        if !log.log.entries.isEmpty {
                            // Disabled, not hidden, while the history is read-only (F187): `clear()` is
                            // guarded and would silently do nothing, and a control that does nothing when
                            // clicked is its own bug. The tooltip carries the reason.
                            Button("Clear All", role: .destructive) { log.clear() }
                                .disabled(!log.health.allowsMutation)
                                .help(log.health.allowsMutation
                                      ? "Remove every dictation from this history. This cannot be undone."
                                      : "Unavailable while the history is read-only — clearing it would write over dictations that could not be read.")
                        }
                    }
                    .padding(.bottom, 8)
                    // The store has recorded the load failure since F187's Task 6, but nothing rendered
                    // it: a degraded log made every dictation and every Clear All a silent no-op. Same
                    // inline advisory vocabulary as the transcript warnings (F30/F32) — tinted surface,
                    // full-contrast text, no action to take here (F187).
                    if let message = log.loadErrorMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .bannerSurface(.orange)
                            .accessibilityElement(children: .combine)
                            .padding(.bottom, 8)
                    }
                    // A separate line, because it means something different (F195): the history was
                    // readable and a WRITE failed, which may succeed next time. Sharing one channel
                    // with the load notice is what let a successful save erase a read-only warning.
                    if let message = log.saveErrorMessage {
                        Label(
                            "The last dictation could not be saved to this history: \(message)",
                            systemImage: "exclamationmark.arrow.circlepath"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .bannerSurface(.orange)
                        .accessibilityElement(children: .combine)
                        .padding(.bottom, 8)
                    }
                    if log.log.entries.isEmpty {
                        // A read-only log will never gain entries, so do not promise that it will —
                        // the advisory directly above already says nothing will be written (F187).
                        if log.health.allowsMutation {
                            Text("Your recent dictations will appear here.")
                                .foregroundStyle(.secondary).padding(.vertical, 12)
                        }
                    } else {
                        ForEach(log.log.entries) { entry in
                            DictationHistoryRow(entry: entry)
                            if entry.id != log.log.entries.last?.id { Divider() }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .cardSurface()
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .navigationTitle("Dictation")
        .onAppear { diag = dictation.diagnostics() }
        // The model picker lives in SettingsView (a separate window) but mutates the SAME
        // @Published selectedEngine, so recompute the engine-specific diagnostics rows the moment it
        // changes — otherwise the tab shows the previous engine's runtime label and a wrong-target
        // Install/Repair button until the user presses Refresh (F26).
        .onChange(of: dictation.selectedEngine) { _, _ in diag = dictation.diagnostics() }
    }

    private func statusRow(_ label: String, _ ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(label)
            Spacer()
        }
    }
}

private struct DictationHistoryRow: View {
    let entry: DictationLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(entry.date, style: .time)
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                content
                badge
            }
            Spacer()
            // Gated on there being text to copy rather than on `isSuccess` (F251). The two agree for
            // every outcome this build writes, because a real failure records `text: ""` — they
            // differ only for an entry a newer build wrote and this build decoded leniently as
            // `.failed`, where the text is intact and withholding Copy would be the wrong answer.
            if !entry.text.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy")
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var content: some View {
        // F266: an outcome this build does not recognise is a version skew, not a failure. It
        // decodes to `.failed` so that one entry cannot make the whole log unreadable, but saying
        // "Failed:" about it states something that did not happen — and `outcomeKind` now carries
        // the real case name, so there is no longer any need to guess.
        if entry.wasRecordedByANewerBuild {
            VStack(alignment: .leading, spacing: 3) {
                Text("Recorded by a newer version of WhisperMeet")
                    .foregroundStyle(.secondary)
                if !entry.text.isEmpty {
                    Text(entry.text).textSelection(.enabled)
                }
            }
        } else {
            knownOutcomeContent
        }
    }

    @ViewBuilder private var knownOutcomeContent: some View {
        switch entry.outcome {
        case .pasted, .clipboard: Text(entry.text).textSelection(.enabled)
        case .empty: Text("(nothing heard)").italic().foregroundStyle(.secondary)
        case .failed(let reason):
            // The transcript is shown whenever there is one, even under the failure styling (F251).
            // A real failure records `text: ""` (`DictationController.fail`), so this only ever adds
            // text in the case F251 created: an outcome from a NEWER build decoded leniently as
            // `.failed`. If that build added a *successful* delivery case, the dictated words are
            // intact on disk, and hiding them here would lose the one thing the user wanted.
            VStack(alignment: .leading, spacing: 3) {
                Text("Failed: \(reason)").foregroundStyle(.orange)
                if !entry.text.isEmpty {
                    Text(entry.text).textSelection(.enabled)
                }
            }
        }
    }

    private var badge: some View {
        var (label, color): (String, Color)
        switch entry.outcome {
        case .pasted: (label, color) = ("pasted", .green)
        case .clipboard: (label, color) = ("clipboard", .blue)
        case .empty: (label, color) = ("empty", .secondary)
        case .failed: (label, color) = ("failed", .orange)
        }
        // The real case name, not "failed" (F266). Showing the name a newer build used is more
        // useful than any label this one could invent, and it is the truth on disk.
        if let kind = entry.outcomeKind { (label, color) = (kind, .secondary) }
        return Text(label)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
