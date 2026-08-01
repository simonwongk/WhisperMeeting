# 003 — Give every custom-styled pressable control real press feedback

- **Status**: TODO
- **Commit**: c2230fa
- **Severity**: MEDIUM
- **Category**: Physicality & origin
- **Estimated scope**: 2 files (`Sources/WhisperMeet/DesignSystem.swift`, `Sources/WhisperMeet/ContentView.swift`), ~20 sites, ~50 lines

## Problem

Press feedback — responding on pointer-*down* — is the foundation of Apple's fluid-interface
guidance, and it is absent from every custom-styled control in the app. `.buttonStyle(.plain)` on
macOS renders **no pressed state at all**, so tinted link-style actions and the marker chips invite
a click that lands with zero visual acknowledgment. (Native bordered/borderless buttons dim
themselves and are fine.)

Representative current code:

```swift
// Sources/WhisperMeet/ContentView.swift:2516-2532 — markerChip (looks like a button, no press state)
Button {
    playback.seek(to: marker.offset)
} label: {
    Text("\(TranscriptFormatter.timestamp(marker.offset))  \(RecordingMarkers.displayLabel(for: marker, at: index + 1))")
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.15), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.orange.opacity(0.25), lineWidth: 1))
}
.buttonStyle(.plain)
```

```swift
// Sources/WhisperMeet/ContentView.swift:393-395 — link-style action (one of ~14)
Button("Check Again") { model.refreshRecordingPreflight() }
    .buttonStyle(.plain)
    .foregroundStyle(.tint)
```

## Target

Two shared `ButtonStyle`s in the design system; every custom pressable adopts one:

```swift
// Sources/WhisperMeet/DesignSystem.swift — add at file end
/// Press feedback for custom-styled controls: macOS's `.plain` style has no pressed state, so
/// these provide the pointer-down acknowledgment fluid interfaces require. The opacity dim
/// survives Reduce Motion; the chip's scale is gated.
struct PressableChipStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Press dim for text/icon "link" buttons. Opacity-only, so no Reduce Motion gate is needed.
struct LinkPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
```

## Repo conventions to follow

- Shared presentation helpers live in `Sources/WhisperMeet/DesignSystem.swift` (exemplars:
  `cardSurface`, `gentleFade`).
- Reduce Motion: movement gates, opacity survives (`gentleFade`, `DesignSystem.swift:41-50`).
- 0.12 s ease-out is inside the repo's feedback budget; do not slow it.

## Steps

1. Add the two `ButtonStyle`s above to `Sources/WhisperMeet/DesignSystem.swift`.
2. In `Sources/WhisperMeet/ContentView.swift`, replace `.buttonStyle(.plain)` per this table
   (line numbers as of commit `c2230fa`; locate each by its quoted context, and STOP on drift):

   | Line | Control | New style |
   | --- | --- | --- |
   | 300 | "Cancel Recording" under the record button | `LinkPressStyle()` |
   | 394 | "Check Again" (preflight panel) | `LinkPressStyle()` |
   | 421 | "Test Recording…" (preflight panel) | `LinkPressStyle()` |
   | 770 | "Rename" (SimpleMarkersList row) | `LinkPressStyle()` |
   | 776 | trash icon (SimpleMarkersList row) | `LinkPressStyle()` |
   | 1446 | ✕ remove (vocabulary list row) | `LinkPressStyle()` |
   | 2385 | ✕ clear-search (find bar) | `LinkPressStyle()` |
   | 2396 | chevron.up previous-match (find bar) | `LinkPressStyle()` |
   | 2402 | chevron.down next-match (find bar) | `LinkPressStyle()` |
   | 2511 | "Add at ‹timestamp›" (markers strip) | `LinkPressStyle()` |
   | 2530 | marker chip (capsule) | `PressableChipStyle()` |
   | 2559 | "N segments may need a look" (quality banner) | `LinkPressStyle()` |
   | 2571 | chevron.up (quality banner) | `LinkPressStyle()` |
   | 2576 | chevron.down (quality banner) | `LinkPressStyle()` |

3. Leave every other `.buttonStyle(.plain)` alone — most importantly the transcript **segment
   rows** (`ContentView.swift:2623`): extra motion there is a settled no (reading surface).

## Boundaries

- Touch ONLY the two files above. No action closures, labels, or layout change — style swaps only.
- Do NOT restyle native bordered/borderless buttons (they already dim), including
  `DictationHistoryRow`'s copy button (`.borderless`).
- Do NOT add hover effects — this plan is press feedback only.
- Repo process: ticket **F119**, `AGENTS.md` rules. STOP on drift from the quoted context.

## Verification

- **Mechanical**: `swift build` clean; `swift test` — all pass, no count drop (baseline 257).
- **Feel check**:
  - Click-and-hold "Check Again", a find-bar chevron, and a marker chip: each visibly acknowledges
    on mouse-*down* (dim; chip also compresses slightly), releasing inside fires the action,
    dragging off and releasing cancels with the label returning to rest.
  - The chip's press must read as subtle — if the scale is noticeable as "an animation," it's too
    much (it should be felt, not seen).
  - Reduce Motion ON: chips no longer scale but still dim; link buttons unchanged (dim only).
  - Transcript segment rows still have no press motion.
- **Done when**: every table row is applied and `grep -n "buttonStyle(.plain)" Sources/WhisperMeet/ContentView.swift` returns only the segment-row site (2623 area).
