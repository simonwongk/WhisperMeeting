# Animation improvement plans

Output of the 2026-07-31 `improve-animations` audit (eight-category workflow audit, every finding
hand-vetted at its cited line; commit `c2230fa`). Board ticket: **F119**. Each plan is
self-contained — an executor needs zero context beyond the plan file and `AGENTS.md`.

## Plans

| # | Plan | Severity | Status |
| --- | --- | --- | --- |
| 001 | [Unify the transcript scroll system](001-transcript-scroll-system.md) | MEDIUM | TODO |
| 002 | [Dictation pill: instant feedback](002-dictation-pill-feedback.md) | MEDIUM | TODO |
| 003 | [Press feedback for custom controls](003-press-feedback-styles.md) | MEDIUM | TODO |
| 004 | [Live meter transform-only](004-live-meter-transform-only.md) | MEDIUM | TODO |
| 005 | [Health-banner status fades](005-health-banner-transition.md) | MEDIUM | TODO |

## Execution order and dependencies

Recommended order: **001 → 004 → 002 → 003 → 005** (leverage order; 001 and 004 first because they
both add tokens to `DesignSystem.swift`).

- 001 and 004 each add an `Animation` token to the same `extension Animation` block in
  `Sources/WhisperMeet/DesignSystem.swift` — execute sequentially, not in parallel worktrees, or
  merge the token additions.
- 002 and 004 both touch `DictationOverlay.swift` (different lines: 002 the pill body/model, 004
  only line 150's animation token swap). Sequential execution avoids any conflict.
- 003 and 005 are independent of everything.
- Every plan: `swift build` + `swift test` must stay green with **no test-count drop**
  (baseline 257), commits reference **F119**, and the feel checks are mandatory (a human or an
  agent driving the built app must actually look).

## Audit record — findings not planned (so they don't die in chat)

Recorded LOW findings, valid but below the cut the user selected (all five MEDIUMs). Re-audit or
promote to plans as desired:

- **E — token completion** (`DesignSystem.swift`): `.smooth(0.22)` hand-typed at
  `ContentView.swift:2621`; gentleFade's `0.2` hardcoded. Plans 001/004 add `transcriptScroll` and
  `meterTracking`; `segmentHighlight` and `reducedMotionFade` tokens remain unadded.
- **F — copy-prompt revert race** (`ContentView.swift:1487`): each "Copy AI Prompt" press spawns
  an independent 2 s revert Task; a stale task can cut a newer confirmation short after ~0.1 s.
  Fix: store and cancel the revert task.
- **G — find-highlight recompute** (`ContentView.swift:2642`): during find + playback, every
  visible row re-runs `TextSearch.occurrenceRanges` and rebuilds an `AttributedString` on each
  4 Hz playback tick. Fix: cache occurrence ranges per segment in `recomputeVisible()`.
- **M2 — waiting-payoff fades**: dictation self-test result line (`DictationView.swift:52`) and
  runtime-install completion rows (`ContentView.swift:1175` area) pop in with a layout jump; both
  fit the F116 `gentleFade` recipe.
- **M3 — sidebar status dot** (`ContentView.swift:198`): processing → completed snaps blue→green;
  a `.smooth(0.22)` color fade (value-scoped to `meeting.status`) would acknowledge the moment
  without touching filtering.

Settled decisions the audit respected (do not re-open without new evidence): the rejected list in
`docs/UI_REDESIGN_LOG.md` § "Motion opportunity sweep", the F116 implementation notes, and the
pill's dark-HUD/no-entrance choices.
