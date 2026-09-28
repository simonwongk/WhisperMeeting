import SwiftUI
import WhisperCore

/// The at-risk recording warning on every pane of the window (F528).
///
/// The health panel that says "Recording needs attention" exists on the New Meeting pane only, so a
/// user reading a meeting's notes or Settings mid-recording learned nothing when a channel died — and
/// the notification held back because a window was open. This sits in the same top overlay as
/// `ReadOnlyLibraryBanner`, is driven by live state rather than posted, and steps aside on the New
/// Meeting pane, where the health panel already says the same thing in more detail.
struct RecordingRiskBanner: View {
    @ObservedObject var model: AppModel
    /// Whether the New Meeting pane — and so the recording's own health panel — is on screen.
    let isHealthPanelShowing: Bool

    var body: some View {
        if let line = model.recordingRiskBannerLine, !isHealthPanelShowing {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(line)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .accessibilityElement(children: .combine)
        }
    }
}
