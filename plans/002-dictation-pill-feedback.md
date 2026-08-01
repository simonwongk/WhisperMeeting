# 002 — Make the dictation pill feel instant: fast phase curve, fixed icon slot, Reduce Motion gate, quantized level

- **Status**: TODO
- **Commit**: c2230fa
- **Severity**: MEDIUM
- **Category**: Easing & duration + accessibility + performance
- **Estimated scope**: 1 file (`Sources/WhisperMeet/Dictation/DictationOverlay.swift`), ~25 lines

## Problem

The dictation pill is the app's highest-frequency motion surface (tens of uses/day; the product
requirement is instant feedback). Three defects:

1. **Confirmation timing is window-class, not feedback-class.** Phase changes ride the app-wide
   0.35 s-response spring — roughly 2× the 100–160 ms feedback budget — so "Pasted" / "Didn't
   catch that" arrive slightly laggy at the exact moment the user is waiting:

   ```swift
   // Sources/WhisperMeet/Dictation/DictationOverlay.swift:108-111 — current
   // Phase changes cross-fade with a critically damped spring; the pill never moves, so this
   // stays gentle under Reduce Motion too.
   .animation(.uiSpring, value: model.phase)
   ```

2. **The pill's content DOES move, and the animation is ungated.** The comment's premise is wrong:
   the icon slot changes width across phases (10 pt `Circle` when listening vs ~16 pt
   `ProgressView`/SF symbols — see the `icon` builder at `DictationOverlay.swift:114-124`), so the
   label slides horizontally on every phase change — layout movement animated with **no**
   `accessibilityReduceMotion` gate, deviating from the repo convention.

3. **The level is published unthrottled at ~47 Hz.** `MicDictationRecorder` installs its tap with
   `bufferSize: 1_024` (`MicDictationRecorder.swift:66`, ≈47 Hz at 48 kHz) and forwards every
   callback (`DictationController.swift:349`) into:

   ```swift
   // Sources/WhisperMeet/Dictation/DictationOverlay.swift:31-33 — current
   func update(level: Float) {
       model.level = level
   }
   ```

   `level` is a raw `Float` that is almost never equal twice, so every audio buffer re-evaluates
   the pill body and retargets the bars' 0.08 s animation — ~3× the app's own 15 Hz meter
   convention, for a display with only 6 visual states (0–5 lit bars).

## Target

- Phase cross-fades at a feedback-class ~150 ms; Reduce Motion users get a same-speed pure fade.
- A fixed-width icon slot so phase changes are pure cross-fades — nothing slides.
- Level publishes only when the number of lit bars changes (visually lossless).

## Repo conventions to follow

- Reduce Motion pattern: springs gate, fades survive — exemplar
  `AnyTransition.gentleFade(reduceMotion:)` in `Sources/WhisperMeet/DesignSystem.swift:41-50`
  (`.opacity.animation(reduceMotion ? .linear(duration: 0.2) : .uiSpring)`).
- Live level feedback stays `.linear(duration: 0.08)` (already correct at
  `DictationOverlay.swift:148-150` — do not change it).
- The dark HUD styling and the absence of an entrance animation are **settled decisions**
  (`docs/UI_REDESIGN_LOG.md`) — do not touch them.

## Steps

1. In `DictationPill` (`DictationOverlay.swift:87` area), add the environment property:
   ```swift
   @Environment(\.accessibilityReduceMotion) private var reduceMotion
   ```
2. Fix the icon slot width. In the pill body's `HStack`, the first child is currently the bare
   `icon`; give it a fixed slot:
   ```swift
   icon
       .frame(width: 18)
   ```
3. Replace the animation line and its comment (current code in Problem #1) with:
   ```swift
   // A feedback pill: phase confirmations land at feedback speed (~150 ms), not the window-class
   // 0.35 s. The fixed icon slot above keeps content from sliding, so under Reduce Motion the
   // same-speed pure fade is safe.
   .animation(
       reduceMotion
           ? .linear(duration: 0.15)
           : .spring(response: 0.15, dampingFraction: 1.0),
       value: model.phase
   )
   ```
4. Quantize the level at the overlay boundary. Add to `PillModel`
   (`DictationOverlay.swift:82-85`) a non-published bucket:
   ```swift
   var levelBucket: Int = -1
   ```
   and replace `update(level:)` (current code in Problem #3) with:
   ```swift
   func update(level: Float) {
       // The mic tap publishes ~47 Hz (1024-frame buffers at 48 kHz); the bars have only six
       // states, so publish only when the lit-bar count changes — visually identical, and it
       // spares a pill re-render per audio buffer.
       let bucket = Int((min(1, max(0, level)) * 5).rounded(.down))
       guard bucket != model.levelBucket else { return }
       model.levelBucket = bucket
       model.level = level
   }
   ```

## Boundaries

- Touch ONLY `Sources/WhisperMeet/Dictation/DictationOverlay.swift`.
- Do NOT touch `MicDictationRecorder.swift` or `DictationController.swift` (functional files) —
  the throttle lives at the presentation boundary.
- Do NOT change the panel mechanics (`NonActivatingPanel`, `show`/`hide`, positioning), the dark
  HUD styling, `LevelBars`' 0.08 s linear animation, or add an entrance animation (settled).
- Repo process: work under ticket **F119** per `AGENTS.md`. If code at any cited line no longer
  matches (drift since `c2230fa`), STOP and report.

## Verification

- **Mechanical**: `swift build` clean; `swift test` — all pass, no count drop (baseline 257).
- **Feel check** (enable Quick Dictation, hold the trigger key, speak, release):
  - "Listening…" → "Transcribing…" → "Pasted" transitions read crisp (~150 ms), not languid.
  - Watch the label text during phase changes: it must not shift horizontally at all.
  - The level bars still track your voice smoothly while speaking.
  - Reduce Motion ON: phase changes are pure quick fades; bars still track.
- **Done when**: all feel checks pass and the pill contains no ungated spring.
