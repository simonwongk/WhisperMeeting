# 004 — Make the live volume meter transform-only (and VU-correct)

- **Status**: TODO
- **Commit**: c2230fa
- **Severity**: MEDIUM
- **Category**: Performance
- **Estimated scope**: 2 files (`Sources/WhisperMeet/ContentView.swift`, `Sources/WhisperMeet/DesignSystem.swift`), ~25 lines

## Problem

`LiveVolumeBar` — on the panel a user watches continuously for an entire meeting — animates a
**layout** property at the ~15 Hz meter rate: every level tick retargets an animation on
`.frame(width:)` inside a `GeometryReader`, invalidating layout of that subtree continuously.
The rule is transform/opacity-only in hot paths.

```swift
// Sources/WhisperMeet/ContentView.swift:1026-1051 — current
GeometryReader { geometry in
    ZStack(alignment: .leading) {
        Capsule()
            .fill(.quaternary.opacity(0.6))
        Capsule()
            .fill(
                LinearGradient(
                    colors: [.green, .yellow, .orange],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: max(4, geometry.size.width * level))
            // Live 15 Hz tracking feedback stays *linear* and short — it must follow
            // the signal 1:1, not spring past it.
            .animation(.linear(duration: 0.08), value: level)
    }
}
.frame(height: 12)
.accessibilityElement(children: .ignore)
.accessibilityLabel(AccessibilityPhrase.levelMeter(
    channel: "Live input",
    level: meter.snapshot.combined
))
```

Side observation the fix also corrects: because the gradient spans the *sized* capsule, a quiet
signal today shows the full green→orange ramp squeezed into a short bar. A real VU meter keeps the
gradient fixed and *reveals* it — quiet shows only green, and orange means the level actually
reached the hot zone.

## Target

Full-width gradient, revealed by a leading-anchored `scaleEffect` mask (a pure transform — no
per-tick layout), same 0.08 s linear tracking, now via a shared token:

```swift
// target — replaces the GeometryReader block above; keep the .frame/.accessibility modifiers below it
Capsule()
    .fill(.quaternary.opacity(0.6))
    .overlay(alignment: .leading) {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [.green, .yellow, .orange],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .mask(alignment: .leading) {
                Rectangle()
                    // Reveal, don't resize: the mask scales (a transform), so the 15 Hz tick
                    // never invalidates layout, and the gradient stays fixed — orange now means
                    // the signal actually reached the hot zone.
                    .scaleEffect(x: max(CGFloat(level), 0.02), y: 1, anchor: .leading)
                    // Live tracking stays *linear* and short — 1:1 with the signal, never a spring.
                    .animation(.meterTracking, value: level)
            }
    }
```

And the token (this also de-duplicates the hand-typed `0.08` in the dictation pill):

```swift
// Sources/WhisperMeet/DesignSystem.swift — add to the existing `extension Animation`
    /// Live level-meter tracking: linear and short, 1:1 with the signal. Shared by the recording
    /// meter and the dictation pill bars so the two can never drift apart.
    static var meterTracking: Animation { .linear(duration: 0.08) }
```

## Repo conventions to follow

- Tokens live in `Sources/WhisperMeet/DesignSystem.swift` next to `uiSpring`.
- The 0.08 s linear value is a documented convention (`docs/UI_REDESIGN_LOG.md`) — this plan moves
  it into a token; it must not change the number.
- Keep the existing `.frame(height: 12)` and both accessibility modifiers exactly as they are.

## Steps

1. `Sources/WhisperMeet/DesignSystem.swift`: add the `meterTracking` token inside the existing
   `extension Animation`.
2. `Sources/WhisperMeet/ContentView.swift` (`LiveVolumeBar`, lines 1026-1044): replace the
   `GeometryReader { … }` block with the target code above. The trailing `.frame(height: 12)`,
   `.accessibilityElement(children: .ignore)`, and `.accessibilityLabel(...)` modifiers stay
   unchanged.
3. `Sources/WhisperMeet/Dictation/DictationOverlay.swift:150`: replace
   `.animation(.linear(duration: 0.08), value: level)` with
   `.animation(.meterTracking, value: level)` (LevelBars — value unchanged, now shared).

## Boundaries

- Do NOT change `RecordingChannelMeter` (native `ProgressView` — fine as is), the meter view-model,
  the level math, or the label above the bar.
- Do NOT change the 0.08 duration or the linear curve.
- Repo process: ticket **F119**, `AGENTS.md` rules. STOP on drift from the quoted code.

## Verification

- **Mechanical**: `swift build` clean; `swift test` — all pass, no count drop (baseline 257).
- **Feel check** (start a recording, speak at varying volume):
  - The bar tracks speech exactly as before — instant, linear, no spring overshoot.
  - Quiet speech shows green only; the bar must reach far right before orange appears (the
    deliberate VU correction — confirm it reads *better*, not different-and-worse).
  - Bar occupies the identical frame (height 12, full card width); VoiceOver still reads
    "Live input level NN percent".
  - The dictation pill's bars behave exactly as before.
- **Done when**: feel checks pass and `grep -rn "linear(duration: 0.08)" Sources/` returns only
  `DesignSystem.swift`.
