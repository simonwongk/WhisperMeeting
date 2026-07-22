// Sources/WhisperMeet/Dictation/DictationOverlay.swift
import AppKit
import SwiftUI

/// An NSPanel that can never become key or main, so it never steals keyboard focus from the app the
/// user is dictating into. (`.nonactivatingPanel` only suppresses app activation; `NSPanel` still
/// defaults `canBecomeKey` to true, so the override is required.)
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A borderless, non-activating panel pinned near the bottom-center of the active screen. It never
/// becomes key, so it never steals focus from the app you are dictating into.
@MainActor
final class DictationOverlay {
    enum Phase: Equatable {
        case listening, transcribing, done, copied, empty, error, busy
    }

    private let model = PillModel()
    private var panel: NSPanel?

    func show(_ phase: Phase) {
        model.phase = phase
        ensurePanel()
        reposition()
        panel?.orderFrontRegardless()
    }

    func update(level: Float) {
        model.level = level
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let hosting = NSHostingView(rootView: DictationPill(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: 220, height: 44)
        let panel = NonActivatingPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = hosting
        self.panel = panel
    }

    private func reposition() {
        guard let panel else { return }
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let size = panel.frame.size
        let origin = NSPoint(
            x: screen.midX - size.width / 2,
            y: screen.minY + 80
        )
        panel.setFrameOrigin(origin)
    }
}

private final class PillModel: ObservableObject {
    @Published var phase: DictationOverlay.Phase = .listening
    @Published var level: Float = 0
}

private struct DictationPill: View {
    @ObservedObject var model: PillModel

    var body: some View {
        HStack(spacing: 10) {
            icon
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 0)
            if model.phase == .listening {
                LevelBars(level: model.level)
            }
        }
        .padding(.horizontal, 16)
        .frame(width: 220, height: 44)
        .background(.black.opacity(0.82), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
    }

    @ViewBuilder private var icon: some View {
        switch model.phase {
        case .listening: Circle().fill(.red).frame(width: 10, height: 10)
        case .transcribing: ProgressView().controlSize(.small).tint(.white)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .copied: Image(systemName: "doc.on.clipboard").foregroundStyle(.white)
        case .empty: Image(systemName: "waveform.slash").foregroundStyle(.yellow)
        case .error: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .busy: Image(systemName: "hourglass").foregroundStyle(.white)
        }
    }

    private var label: String {
        switch model.phase {
        case .listening: "Listening…"
        case .transcribing: "Transcribing…"
        case .done: "Pasted"
        case .copied: "Copied to clipboard"
        case .empty: "Didn’t catch that"
        case .error: "Dictation failed"
        case .busy: "Busy…"
        }
    }
}

private struct LevelBars: View {
    let level: Float
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(barOpacity(index)))
                    .frame(width: 3, height: 6 + CGFloat(index) * 3)
            }
        }
    }
    private func barOpacity(_ index: Int) -> Double {
        Double(level) * 5 > Double(index) ? 0.95 : 0.25
    }
}
