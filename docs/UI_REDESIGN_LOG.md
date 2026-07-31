# UI redesign log (F113 + F87)

Change-by-change record of the 2026-07-31 presentation-only redesign pass. Every entry lists the
file, what changed, and why. **Scope rule for this pass: presentation only** — no change to
`AppModel`, `MeetingStore`, `AudioCaptureEngine`, dictation controllers, or any `WhisperCore`
behaviour. Every action, binding, dialog, sheet, and state machine keeps its exact call path.

Status: **in progress** — this file is completed in the implementation commit.

## Design direction

Derived from Apple's design guidance (Designing Fluid Interfaces, WWDC 2018; HIG):

1. **One surface language.** A single card/banner vocabulary (continuous-corner rounded
   rectangles, one fill, hairline edge) replaces the four ad-hoc `.quaternary.opacity(…)` fills and
   corner radii 6/8/10/12 that accreted per feature.
2. **Springs, critically damped.** State-driven transitions use a `response ≈ 0.35`,
   `dampingFraction 1.0` spring (no overshoot — nothing here carries gesture momentum).
3. **Motion respects the user.** Pulse effects and layout springs are gated on
   `accessibilityReduceMotion`.
4. **Type that scales.** Fixed-point fonts are replaced by semantic text styles or `@ScaledMetric`
   so the layout follows the user's text size (F87).
5. **Continuous feedback stays continuous.** The 15 Hz level meters keep their short *linear*
   animation — live-tracking feedback must track 1:1, not spring.
6. **Accessibility is part of the design.** The tested `AccessibilityPhrase` labels are attached
   (record button, markers, level meters) per F87.

## Changes

_To be filled in the implementation commit._
