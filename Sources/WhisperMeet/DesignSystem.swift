// Sources/WhisperMeet/DesignSystem.swift
import SwiftUI

/// The app's shared visual language (F113): one surface, banner, and motion vocabulary so panels
/// added in different rounds read as a single designed system. Presentation only — these helpers
/// hold no state and perform no side effects.
extension View {
    /// A soft rounded surface for grouped content: continuous corners, one quiet fill, and a
    /// hairline edge. Replaces the per-feature `.quaternary.opacity(…)` fills.
    func cardSurface(cornerRadius: CGFloat = 14) -> some View {
        background(
            .quaternary.opacity(0.35),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.separator.opacity(0.55), lineWidth: 1)
        )
    }

    /// A tinted advisory surface (warnings, review prompts). The tint stays in the background so
    /// the text keeps full contrast.
    func bannerSurface(_ tint: Color, cornerRadius: CGFloat = 10) -> some View {
        background(
            tint.opacity(0.12),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 1)
        )
    }
}

extension Animation {
    /// The app-wide default spring: critically damped (no overshoot), ~0.35 s response — Apple's
    /// guidance for state changes that carry no gesture momentum. Callers gate it on
    /// `accessibilityReduceMotion` when it drives layout movement.
    static var uiSpring: Animation { .spring(response: 0.35, dampingFraction: 1.0) }
}
