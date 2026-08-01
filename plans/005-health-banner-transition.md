# 005 — Fade the recording-health banner's status changes instead of teleporting them

- **Status**: TODO
- **Commit**: c2230fa
- **Severity**: MEDIUM
- **Category**: Missed opportunity (state indication / preventing a jarring change)
- **Estimated scope**: 1 file (`Sources/WhisperMeet/ContentView.swift`), ~10 lines

## Problem

The recording-health banner is the one surface a user stares at during an entire meeting. When
`overallStatus` flips (healthy → channel stopped → recovered), the icon, its tint, the title, and
the reason text all hard-swap in a single frame. A sudden red flip with no transition reads as a
glitch rather than a monitored state change — on exactly the surface whose job is to look
trustworthy.

```swift
// Sources/WhisperMeet/ContentView.swift:525-540 — current
private func healthStatusBanner(_ health: RecordingHealthSnapshot) -> some View {
    HStack(spacing: 11) {
        Image(systemName: statusIcon(health.overallStatus))
            .font(.title3)
            .foregroundStyle(statusColor(health.overallStatus))
        VStack(alignment: .leading, spacing: 2) {
            Text(statusTitle(health.overallStatus))
                .fontWeight(.semibold)
            Text(statusReason(health))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Spacer()
    }
}
```

## Target

Color/text cross-fades only — no layout motion, so it is safe under Reduce Motion by the repo's
convention; the icon swap uses a symbol replace, gated to a plain fade for Reduce Motion users:

```swift
// target
private func healthStatusBanner(_ health: RecordingHealthSnapshot) -> some View {
    HStack(spacing: 11) {
        Image(systemName: statusIcon(health.overallStatus))
            .font(.title3)
            .foregroundStyle(statusColor(health.overallStatus))
            .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
        VStack(alignment: .leading, spacing: 2) {
            Text(statusTitle(health.overallStatus))
                .fontWeight(.semibold)
                .contentTransition(.opacity)
            Text(statusReason(health))
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
        Spacer()
    }
    // The continuously watched surface: status flips fade (color/text only, no movement)
    // instead of teleporting, so a warning reads as a monitored transition, not a glitch.
    .animation(.smooth(duration: 0.22), value: health.overallStatus)
    .animation(.smooth(duration: 0.22), value: health.warnings)
}
```

Note the second `.animation` keyed on `health.warnings`: the reason line can change while
`overallStatus` stays the same (e.g. one warning replaces another), and both changes should fade.

## Repo conventions to follow

- `.smooth(duration: 0.22)` is the repo's established color-fade value (exemplar: the transcript
  active-segment highlight, `ContentView.swift:2621`).
- Color/opacity-only changes are allowed under Reduce Motion (convention documented in
  `docs/UI_REDESIGN_LOG.md`); movement is not — hence no layout animation here.
- `RecordMeetingView` already has `@Environment(\.accessibilityReduceMotion) private var reduceMotion`
  (declared near line 243) — `healthStatusBanner` is a member of it, so `reduceMotion` is in scope.

## Steps

1. `Sources/WhisperMeet/ContentView.swift`, `healthStatusBanner` (lines 525-540): apply the target
   code — three `.contentTransition` modifiers and the two `.animation(_, value:)` modifiers on
   the `HStack`. Nothing else changes.

## Boundaries

- Touch ONLY `healthStatusBanner`. Explicitly out of scope: the per-channel rows
  (`RecordingChannelHealthRow`) — their activity text ("Receiving audio" ↔ "Silent") flips at
  conversation cadence, and a cross-fade there would keep the text perpetually mid-fade; they stay
  instant by design.
- No layout animation, no springs, no icon size/position changes.
- `RecordingHealthStatus` and `[RecordingHealthWarning]` are `Equatable` enums/arrays — if the
  compiler disagrees (drift since `c2230fa`), STOP and report rather than adding conformances.
- Repo process: ticket **F119**, `AGENTS.md` rules.

## Verification

- **Mechanical**: `swift build` clean; `swift test` — all pass, no count drop (baseline 257).
- **Feel check** (start a recording with system audio muted so `.systemAudioNotDetected` fires,
  then play some system audio so it recovers):
  - The banner's icon/color/title/reason cross-fade over ~0.2 s on each status change — nothing
    jumps, nothing moves position.
  - Trigger a second warning type (e.g. stay silent 3+ s for a capture-stopped warning) and
    confirm the reason line fades between warnings even when the overall color does not change.
  - Reduce Motion ON: the changes still fade (opacity only); the icon no longer uses the symbol
    morph.
  - The per-channel rows below still switch instantly.
- **Done when**: all feel checks pass with no layout shift visible in the banner at any flip.
