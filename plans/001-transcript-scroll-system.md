# 001 — Unify the transcript scroll system: one spring token, Reduce Motion gating, scroll ownership

- **Status**: TODO
- **Commit**: c2230fa
- **Severity**: MEDIUM
- **Category**: Interruptibility + cohesion + accessibility + purpose/frequency
- **Estimated scope**: 2 files (`Sources/WhisperMeet/ContentView.swift`, `Sources/WhisperMeet/DesignSystem.swift`), ~35 lines

## Problem

`PlayableTranscriptView` (in `Sources/WhisperMeet/ContentView.swift`) has three scroll-to-center
animations that predate the design system. Five defects, one seam:

```swift
// Sources/WhisperMeet/ContentView.swift:2443-2460 — current
.onChange(of: activeIndex) { _, newValue in
    guard followPlayback, !isSearching, let newValue else { return }
    withAnimation(.easeInOut(duration: 0.2)) {
        proxy.scrollTo(newValue, anchor: .center)
    }
}
.onChange(of: selectedSearchID) { _, newValue in
    guard isSearching, let newValue else { return }
    withAnimation(.easeInOut(duration: 0.15)) {
        proxy.scrollTo(newValue, anchor: .center)
    }
}
.onChange(of: reviewNudge) { _, _ in
    guard let target = reviewTargetID else { return }
    withAnimation(.easeInOut(duration: 0.2)) {
        proxy.scrollTo(target, anchor: .center)
    }
}
```

1. **Hand-typed, disagreeing curves.** These are the app's only `.easeInOut` animations (the
   vocabulary is otherwise the critically damped `Animation.uiSpring`), and the same gesture uses
   0.2 s in two places and 0.15 s in one, for no stated reason.
2. **Zero-velocity restarts.** A fixed-duration tween restarts from zero on every retarget. The
   follow-playback scroll retargets while the user scrubs the player (playback time updates 4 Hz),
   producing a stop-start lurch. Springs carry velocity through retargets.
3. **No Reduce Motion handling.** `PlayableTranscriptView` has no
   `@Environment(\.accessibilityReduceMotion)`; a Reduce Motion user gets animated autoscroll for
   an entire playback session on a surface the repo designates a reading surface.
4. **Keystroke-driven glide.** Typing in Find calls `recomputeVisible()`
   (`ContentView.swift:2325-2337`), which resets `selectedSearchPosition = 0`; when that changes
   `selectedSearchID`, the middle `onChange` runs a 0.15 s glide — an animated response to typing,
   contradicting the repo's settled instant-search principle. Only the explicit chevron navigation
   (`moveSearchSelection(by:)`, `ContentView.swift:2338-2344`) should glide.
5. **Scroll-ownership race.** `moveReview(by:)` (`ContentView.swift:2356-2361`) and the
   quality-banner tap (`reviewNudge += 1` inside `qualityReviewBanner`,
   `ContentView.swift:2547-2582`) jump to a flagged segment but do not suspend Follow; with audio
   playing, the next `activeIndex` change yanks the viewport back to the playing segment within
   seconds. Search already solves this exact conflict via its `isSearching` guards.

## Target

- One named token; all three scrolls use it, gated on Reduce Motion (instant jump, still scrolls):

```swift
// Sources/WhisperMeet/DesignSystem.swift — add to the existing `extension Animation`
    /// Scroll-to-segment motion in the playable transcript. A spring (not a fixed tween) so rapid
    /// retargets — e.g. follow-playback while the user scrubs — carry velocity instead of
    /// restarting from zero.
    static var transcriptScroll: Animation { .uiSpring }
```

- Follow scroll: `withAnimation(reduceMotion ? nil : .transcriptScroll)`.
- Search scroll: animated **only** when triggered by chevron navigation; instant when triggered by
  typing.
- Review scroll: `withAnimation(reduceMotion ? nil : .transcriptScroll)`, and both review triggers
  set `followPlayback = false` so the user's deliberate navigation owns the viewport (the Follow
  toggle visibly switching off is the state indication).

## Repo conventions to follow

- Motion tokens live in `Sources/WhisperMeet/DesignSystem.swift` (`Animation.uiSpring` is the
  exemplar; add `transcriptScroll` beside it).
- Reduce Motion pattern (exemplar `ContentView.swift:315`):
  `.animation(reduceMotion ? nil : .uiSpring, value: model.recordingState)` — springs gate to
  `nil`, the action itself still happens.
- Comments state constraints, not narration (see the comment style at `ContentView.swift:1035-1041`).

## Steps

1. `Sources/WhisperMeet/DesignSystem.swift`: add the `transcriptScroll` token shown above inside
   the existing `extension Animation` block (after `uiSpring`).
2. `Sources/WhisperMeet/ContentView.swift`, `PlayableTranscriptView` property block (the struct
   begins near line 2246; add alongside the existing `@State` properties):
   ```swift
   @Environment(\.accessibilityReduceMotion) private var reduceMotion
   // Distinguishes chevron navigation (glides) from typing (snaps): recomputeVisible() leaves
   // this false; moveSearchSelection(by:) sets it just before changing the selection.
   @State private var animateNextSearchScroll = false
   ```
3. Replace the three `onChange` bodies (current code quoted above) with:
   ```swift
   .onChange(of: activeIndex) { _, newValue in
       guard followPlayback, !isSearching, let newValue else { return }
       withAnimation(reduceMotion ? nil : .transcriptScroll) {
           proxy.scrollTo(newValue, anchor: .center)
       }
   }
   .onChange(of: selectedSearchID) { _, newValue in
       guard isSearching, let newValue else { return }
       // Typing snaps to the first match instantly; only chevron navigation glides.
       withAnimation(animateNextSearchScroll && !reduceMotion ? .transcriptScroll : nil) {
           proxy.scrollTo(newValue, anchor: .center)
       }
       animateNextSearchScroll = false
   }
   .onChange(of: reviewNudge) { _, _ in
       guard let target = reviewTargetID else { return }
       withAnimation(reduceMotion ? nil : .transcriptScroll) {
           proxy.scrollTo(target, anchor: .center)
       }
   }
   ```
4. In `moveSearchSelection(by:)` (`ContentView.swift:2338-2344`), set the flag before changing the
   selection:
   ```swift
   private func moveSearchSelection(by offset: Int) {
       guard !searchOccurrences.isEmpty else { return }
       animateNextSearchScroll = true
       selectedSearchPosition = (
           selectedSearchPosition + offset + searchOccurrences.count
       ) % searchOccurrences.count
   }
   ```
5. In `moveReview(by:)` (`ContentView.swift:2356-2361`), add
   `followPlayback = false` as the first line after the guard, with the comment
   `// A deliberate jump owns the viewport; Follow visibly disengages (re-enable to resume).`
6. In `qualityReviewBanner`, the headline button action currently reads `reviewNudge += 1`
   (`ContentView.swift:2551-2553`); change it to:
   ```swift
   followPlayback = false
   reviewNudge += 1
   ```

## Boundaries

- Touch ONLY the two files above, only at the cited sites.
- Do NOT change search filtering logic, `TextSearch`, `recomputeVisible()`'s reset behavior, the
  playback controller, or segment rows.
- Known pre-existing quirk, out of scope: stepping between two occurrences inside the same segment
  does not re-scroll (`selectedSearchID` doesn't change). Leave it.
- No new dependencies. Presentation only — no store/model calls added or removed.
- Repo process: work under ticket **F119** per `AGENTS.md` (claim on the board, reference F119 in
  the commit message). If the code at any cited line no longer matches the excerpts (drift since
  commit `c2230fa`), STOP and report instead of improvising.

## Verification

- **Mechanical**: `swift build` clean; `swift test` — all tests pass with **no count drop**
  (baseline 257).
- **Feel check** (build via `Scripts/build-app.sh`, open a transcribed meeting):
  - Drag the player scrubber back and forth quickly with Follow on: the viewport chases smoothly,
    never stutter-restarting.
  - Type in Find: the list and the jump to the first match are instant — no glide on any keystroke.
  - Press the search chevrons: the jump glides with the spring.
  - With audio playing and Follow on, tap the quality banner: the viewport moves to the flagged
    segment, the Follow toggle visibly turns off, and the viewport is NOT yanked back at the next
    segment boundary. Re-enabling Follow resumes tracking.
  - System Settings → Accessibility → Motion → Reduce Motion ON: all three scrolls become instant
    jumps (no glide anywhere), and everything still navigates.
- **Done when**: all feel checks pass and `git grep -n "easeInOut" Sources/WhisperMeet` returns no
  transcript-scroll sites.
