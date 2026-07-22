import SwiftUI
import AppKit
import WhisperCore

struct DictationView: View {
    @ObservedObject var dictation: DictationController
    @ObservedObject var log: DictationLogStore
    @ObservedObject var model: AppModel
    @State private var diag = DictationDiagnostics(
        runtimeInstalled: false, helperInstalled: false, turboCached: false,
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

                GroupBox("Status & diagnostics") {
                    VStack(alignment: .leading, spacing: 10) {
                        statusRow("Local Whisper runtime", diag.runtimeInstalled)
                        statusRow("Dictation helper installed", diag.helperInstalled)
                        statusRow("Turbo model downloaded", diag.turboCached)
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
                            if !diag.runtimeInstalled || !diag.helperInstalled {
                                Button("Install / Repair Local Whisper") { model.installLocalWhisper() }
                                    .disabled(model.isInstallingRuntime)
                            }
                            Spacer()
                        }
                        if let result = dictation.selfTestResult {
                            Text(result)
                                .font(.callout)
                                .foregroundStyle(result.hasPrefix("✓") ? .green : .orange)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: dictation.isSelfTesting) { _, testing in if !testing { diag = dictation.diagnostics() } }

                GroupBox {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("History").font(.headline)
                            Spacer()
                            if !log.log.entries.isEmpty {
                                Button("Clear All", role: .destructive) { log.clear() }
                            }
                        }
                        .padding(.bottom, 8)
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
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .navigationTitle("Dictation")
        .onAppear { diag = dictation.diagnostics() }
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
