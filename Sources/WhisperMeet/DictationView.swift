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
                    if log.log.entries.isEmpty {
                        Text("Your recent dictations will appear here.")
                            .foregroundStyle(.secondary).padding(.vertical, 12)
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
            if entry.isSuccess {
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
        switch entry.outcome {
        case .pasted, .clipboard: Text(entry.text).textSelection(.enabled)
        case .empty: Text("(nothing heard)").italic().foregroundStyle(.secondary)
        case .failed(let reason): Text("Failed: \(reason)").foregroundStyle(.orange)
        }
    }

    private var badge: some View {
        let (label, color): (String, Color)
        switch entry.outcome {
        case .pasted: (label, color) = ("pasted", .green)
        case .clipboard: (label, color) = ("clipboard", .blue)
        case .empty: (label, color) = ("empty", .secondary)
        case .failed: (label, color) = ("failed", .orange)
        }
        return Text(label)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
