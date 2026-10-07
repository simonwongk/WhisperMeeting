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

/// The pill's view host, taking the first click: the panel never becomes key, and without this the
/// click on Copy would be spent trying to make it so (F586).
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A borderless, non-activating panel pinned near the bottom-center of the active screen. It never
/// becomes key, so it never steals focus from the app you are dictating into.
@MainActor
final class DictationOverlay {
    enum Phase: Equatable {
        case listening, transcribing, refining, done, copied, empty, error, busy
        /// The dictation model's first-run download is running (F823): a press is refused with it,
        /// and a dictation already waiting on the model shows it instead of "Transcribing…".
        case modelDownloading
        /// Pasted, but no text field could be seen to take it, so it is on the clipboard too (F600).
        case pastedUnconfirmed
        /// Copied rather than pasted: the app in front is not the one the key was pressed in (F445).
        case appChanged
        /// Not pasted because of secure input (F445), and not on the clipboard either: the pill
        /// offers Copy (F586).
        case secureInput
        /// As `secureInput`, with the app the window server names for it (F585) — the app in front
        /// when secure input came on, which is a hint and not the owner.
        case secureKeyboardEntry(app: String)

        /// The pill has a Copy button, the only way to a dictation made into secure input (F586).
        var offersCopy: Bool {
            switch self {
            case .secureInput, .secureKeyboardEntry: true
            default: false
            }
        }

        /// Wider when it offers Copy: the button (48 pt measured) and a caption such as "It came on
        /// while Terminal was in front" (197 pt at 11 pt) then fit beside the icon, in the ~222 pt
        /// left; the caption may scale to 0.75, so names up to ~296 pt of caption still fit.
        var pillWidth: CGFloat { offersCopy ? 340 : 220 }

        /// A second, smaller line under the label, or nil (F585).
        ///
        /// Says only when secure input came on, not who holds it: the window server's key names
        /// the app that was in front then, and a background process turning secure input on is
        /// attributed to that app (measured 2026-09-28), so "Secure Keyboard Entry is on in Chrome"
        /// would send the user looking for a setting Chrome does not have. The label above it
        /// already says "Not pasted — secure input".
        var caption: String? {
            if case let .secureKeyboardEntry(app) = self { return "It came on while \(app) was in front" }
            return nil
        }
    }

    private let model = PillModel()
    private var panel: NSPanel?

    /// The Copy button's action (F586), set by the controller.
    var onCopy: (() -> Void)? {
        didSet { model.onCopy = onCopy }
    }

    func show(_ phase: Phase) {
        if phase == .listening {
            // A new dictation session: clear the previous session's level so stale bars never
            // flash before the first mic callback lands.
            model.levelBucket = -1
            model.level = 0
        }
        model.phase = phase
        ensurePanel()
        // Clicks pass through the pill to whatever is under it, except while it has a button.
        panel?.ignoresMouseEvents = !phase.offersCopy
        panel?.setContentSize(NSSize(width: phase.pillWidth, height: 44))
        reposition()
        panel?.orderFrontRegardless()
    }

    func update(level: Float) {
        // The mic tap publishes ~47 Hz (1024-frame buffers at 48 kHz); the bars have only six
        // states, so publish only when the lit-bar count changes — visually identical, and it
        // spares a pill re-render per audio buffer.
        let bucket = DictationPillLevelBucket.bucket(for: level)
        guard bucket != model.levelBucket else { return }
        model.levelBucket = bucket
        model.level = level
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let hosting = FirstClickHostingView(rootView: DictationPill(model: model))
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

@MainActor
protocol DictationOverlayPresenting: AnyObject {
    func show(_ phase: DictationOverlay.Phase)
    func update(level: Float)
    func hide()
    /// What the pill's Copy button does (F586). The controller sets it once.
    var onCopy: (() -> Void)? { get set }
}

extension DictationOverlayPresenting {
    /// A presenter with no Copy button ignores the action.
    var onCopy: (() -> Void)? {
        get { nil }
        set {}
    }
}

extension DictationOverlay: DictationOverlayPresenting {}

enum DictationPillLevelBucket {
    static func bucket(for level: Float) -> Int {
        // The arithmetic stays in `Float` and only the finished value widens. Converting the
        // input instead changes the answer: `Double(Float(0.2)) * 5` is 1.0000000149…, which
        // `rounded(.up)` takes to 2, where the Float computation gives exactly 1. F120's
        // bucket-equals-bars test caught that, which is the only reason this comment exists.
        let scaled = min(1, max(0, level)) * 5
        return scaled == 0 ? 0 : Int(saturating: Double(scaled.rounded(.up)))
    }
}

private final class PillModel: ObservableObject {
    @Published var phase: DictationOverlay.Phase = .listening
    @Published var level: Float = 0
    var levelBucket: Int = -1
    /// The Copy button's action (F586).
    var onCopy: (() -> Void)?
}

private struct DictationPill: View {
    @ObservedObject var model: PillModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    // Two lines, for the label that needs them: "Pasted — also on the clipboard"
                    // (F600) measures 191 pt at this font against the 160 pt left beside the icon
                    // in a 220 pt pill; two 15.3 pt lines fit the 44 pt height. Every other label
                    // is one line.
                    .lineLimit(2)
                    .contentTransition(.opacity)
                if let caption = model.phase.caption {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            Spacer(minLength: 0)
            if model.phase == .listening {
                LevelBars(level: model.level)
            }
            if model.phase.offersCopy {
                // The only way to a dictation made into secure input: it is on no clipboard until
                // this is pressed (F586).
                Button("Copy") { model.onCopy?() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .environment(\.colorScheme, .dark)
            }
        }
        .padding(.horizontal, 16)
        .frame(width: model.phase.pillWidth, height: 44)
        // A deliberate dark HUD (like the system dictation pill): readable over any app beneath,
        // in either appearance. The brighter top-edge stroke reads as light catching the surface.
        .background(.black.opacity(0.78), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
        // A feedback pill: phase confirmations land at feedback speed (~150 ms), not the window-class
        // 0.35 s. The fixed icon slot above keeps content from sliding, so under Reduce Motion the
        // same-speed pure fade is safe.
        .animation(
            reduceMotion
                ? .linear(duration: 0.15)
                : .spring(response: 0.15, dampingFraction: 1.0),
            value: model.phase
        )
    }

    @ViewBuilder private var icon: some View {
        switch model.phase {
        case .listening: Circle().fill(.red).frame(width: 10, height: 10)
        case .transcribing, .refining: ProgressView().controlSize(.small).tint(.white)
        case .done, .pastedUnconfirmed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .copied, .appChanged: Image(systemName: "doc.on.clipboard").foregroundStyle(.white)
        case .secureInput, .secureKeyboardEntry: Image(systemName: "lock.fill").foregroundStyle(.white)
        case .empty: Image(systemName: "waveform.slash").foregroundStyle(.yellow)
        case .error: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .busy: Image(systemName: "hourglass").foregroundStyle(.white)
        case .modelDownloading: Image(systemName: "arrow.down.circle").foregroundStyle(.white)
        }
    }

    private var label: String {
        switch model.phase {
        case .listening: "Listening…"
        case .transcribing: "Transcribing…"
        case .refining: "Polishing…"
        case .done: "Pasted"
        case .pastedUnconfirmed: "Pasted — also on the clipboard"
        case .copied: "Copied to clipboard"
        case .appChanged: "Copied — app changed"
        case .secureInput, .secureKeyboardEntry: "Not pasted — secure input"
        case .empty: "Didn’t catch that"
        case .error: "Dictation failed"
        case .busy: "Busy…"
        case .modelDownloading: "Downloading model…"
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
        // Live level feedback tracks 1:1 — short linear fade, never a spring.
        .animation(.meterTracking, value: level)
    }
    private func barOpacity(_ index: Int) -> Double {
        Double(level) * 5 > Double(index) ? 0.95 : 0.25
    }
}
