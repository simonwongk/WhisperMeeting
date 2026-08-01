# UI redesign log (F113 + F87)

Change-by-change record of the 2026-07-31 presentation-only redesign pass. Every entry lists the
file, what changed (before → after), and why. **Scope rule for this pass: presentation only** — no
change to `AppModel`, `MeetingStore`, `AudioCaptureEngine`, the dictation controllers, or any
`WhisperCore` behaviour. Every action, binding, dialog, sheet, and state machine keeps its exact
call path; the full diff was reviewed hunk-by-hunk against that rule before commit.

## Design direction

Derived from Apple's design guidance (Designing Fluid Interfaces, WWDC 2018; the HIG):

1. **One surface language.** A single card/banner vocabulary (continuous-corner rounded
   rectangles, one quiet fill, hairline edge) replaces the four ad-hoc `.quaternary.opacity(…)`
   fills and corner radii 6/8/10/12 that accreted per feature.
2. **Springs, critically damped.** State-driven transitions use a `response 0.35`,
   `dampingFraction 1.0` spring (no overshoot — nothing here carries gesture momentum, so bounce
   would be wrong per Apple's damping guidance).
3. **Motion respects the user.** Pulse effects and layout springs are gated on
   `accessibilityReduceMotion`. Color-only fades (segment highlight, pill phase) are kept — Apple's
   reduced-motion guidance keeps non-vestibular opacity/color feedback.
4. **Type that scales.** Fixed-point fonts are replaced by semantic text styles or `@ScaledMetric`
   so layout follows the user's text size (F87).
5. **Continuous feedback stays continuous.** The ~15 Hz level meters keep a short *linear*
   animation — live-tracking feedback must follow the signal 1:1, never spring past it.
6. **Accessibility is part of the design.** The unit-tested `AccessibilityPhrase` labels are
   attached (record button, markers, level meters) per F87.

## New file

### `Sources/WhisperMeet/DesignSystem.swift`
- `View.cardSurface(cornerRadius: 14)` — the shared card: `.quaternary.opacity(0.35)` fill in a
  continuous-corner rounded rectangle with a `.separator.opacity(0.55)` hairline stroke.
- `View.bannerSurface(_ tint:, cornerRadius: 10)` — the shared advisory banner: `tint.opacity(0.12)`
  fill + `tint.opacity(0.22)` hairline; tint stays in the background so text keeps full contrast.
- `Animation.uiSpring` — `.spring(response: 0.35, dampingFraction: 1.0)`, the app-wide default for
  state changes without gesture momentum.
- Stateless, side-effect free; internal so all three view files share one vocabulary.

## `Sources/WhisperMeet/ContentView.swift`

### Sidebar (`MeetingRow`)
- Tag chips: padding 5×1 → 6×2 (breathing room; text no longer touches the capsule edge).

### Record screen (`RecordMeetingView`)
- **Hero:** bare 58 pt state icon → `heroBadge`, a tinted orb (fill `tint.opacity(0.13)`, hairline
  ring) around the state icon at `@ScaledMetric(relativeTo: .largeTitle)` 44 pt. Tint red while
  recording / accent while idle; `.symbolEffect(.pulse)` now only while recording **and** Reduce
  Motion is off; `.accessibilityHidden(true)` (decorative — the title carries the state).
- **Layout transition:** the idle ⇄ recording panel swap animates with `.uiSpring`, disabled
  entirely under Reduce Motion (`.animation(reduceMotion ? nil : .uiSpring, value:
  model.recordingState)`).
- **Primary button:** `.buttonBorderShape(.capsule)`; disabled condition refactored verbatim into
  `isPrimaryActionBusy` (identical expression, no behaviour change) and reused for the new
  **F87 label** `AccessibilityPhrase.recordButton(isRecording:isBusy:)` — VoiceOver now announces
  "Start recording" / "Stop recording" / "Recording controls unavailable".
- **Live timer:** `.system(.title, design: .monospaced)` → `.system(.largeTitle, design: .rounded)`
  + `.monospacedDigit()` — scales with the user's text size (F87), keeps tabular digits.
- **Preflight and health panels:** ad-hoc `.quaternary.opacity(0.45)` radius-12 fills → shared
  `cardSurface()`, padding 16 → 18.

### Pre-transcript markers (`SimpleMarkersList`)
- Timestamp + label pair grouped as **one VoiceOver element** with
  `AccessibilityPhrase.marker(label:offset:)` ("Marker <label> at MM:SS", F87); the Rename/Delete
  buttons remain individually reachable.
- Panel: `.quaternary.opacity(0.35)` radius-10 → `cardSurface(cornerRadius: 12)`, padding 12 → 14.

### Preflight test sheet (`PreflightTestSheet`)
- Fixed fonts (40/48/30/34 pt — the F87-cited sites) → `@ScaledMetric`: `heroSymbolSize` 40
  (rel. largeTitle), `countdownSize` 48 (rel. largeTitle), one unified `statusSymbolSize` 32
  (rel. title) for the result/failed icons.
- Countdown: monospaced design → rounded design + `.monospacedDigit()`.
- Pulse on the test icon gated on Reduce Motion.
- Channel rows → `cardSurface(cornerRadius: 10)`; playback clip corner 8 → 10 continuous.

### Level meters
- `LiveVolumeBar`: track fill softened (`.quaternary.opacity(0.6)`), height 14 → 12; hardcoded
  "Live input volume" label + percent value → **F87** `AccessibilityPhrase.levelMeter(channel:
  "Live input", level:)` as a single ignored-children element. The 0.08 s *linear* tracking
  animation is deliberately kept (1:1 feedback, documented in-source).
- `RecordingChannelMeter`: generic percent value → **F87**
  `AccessibilityPhrase.levelMeter(channel: "Microphone"/"System audio", level:)`.

### Settings (`SettingsView`)
- All five section headers get icon labels: Local recognition `waveform.circle`, Meeting library
  `books.vertical`, Transcription `captions.bubble`, Quick Dictation `keyboard`, Claude Summaries
  `sparkles`. Grouped-form structure, every control, and all copy unchanged.

### Vocabulary (`VocabularyView`)
- Term list: `.alternatingRowBackgrounds()`, continuous radius 12 clip, hairline border — matches
  the card language.

### Meeting detail (`TranscriptDetailView`)
- **Header metadata** (date/duration/language/confidence): plain secondary labels → quiet capsule
  `metadataChip`s; date format `.long` → `.abbreviated` so chips scan in one line. The outer
  `.foregroundStyle(.secondary)` was removed, returning "Show Recording in Finder" to standard
  button styling (chips carry their own secondary style).
- **Status card** and **summary body**: ad-hoc fills → `cardSurface()`, padding unified at 18.
- **Alignment / language warnings**: ad-hoc orange/red fills → `bannerSurface(.orange)` /
  `bannerSurface(.red)` (adds the matching hairline).
- **Transcript text editor**: radius 10 → 12 continuous, matching stroke.
- **Recording player**: corners → continuous.

### Playable transcript (`PlayableTranscriptView`)
- Inline player, find bar, markers strip: ad-hoc fills/radii → `cardSurface(cornerRadius: 10)`
  (player corners continuous); segment scroll container radius 10 → 12 continuous.
- Quality-review banner → `bannerSurface(.orange)`.
- **Marker chips**: hairline orange stroke added; **F87** `AccessibilityPhrase.marker` label on each
  chip button.
- **Segment rows**: highlight rectangle radius 6 → 7 continuous; the active-segment highlight now
  *fades* between rows (`.smooth(duration: 0.22)` on `isActive`) instead of cutting — a color-only
  change, safe under Reduce Motion.

## `Sources/WhisperMeet/DictationView.swift`
- Both stock `GroupBox`es → the shared `cardSurface()` card with headline icon labels
  ("Status & diagnostics" `stethoscope`, "History" `clock.arrow.circlepath`). All rows, buttons,
  the self-test flow, and the `.onChange(of: dictation.isSelfTesting)` diagnostics refresh are
  unchanged and verified present in the diff.

## `Sources/WhisperMeet/Dictation/DictationOverlay.swift` (pill visuals only)
- Kept the deliberate dark-HUD look (readable over any app beneath, either appearance) — documented
  in-source; background 0.82 → 0.78 opacity, stroke 0.12 → 0.16 (the brighter edge reads as light
  catching the surface).
- Phase changes (Listening → Transcribing → Pasted…) now cross-fade with `.uiSpring` +
  `.contentTransition(.opacity)` instead of hard-cutting; the pill never moves, so this stays
  gentle under Reduce Motion.
- `LevelBars` gets the same 0.08 s linear tracking animation as the in-app meters.
- The `NonActivatingPanel` mechanics (never-key panel, positioning, ordering) are untouched.

## `Tests/WhisperCoreTests/AccessibilityPhraseTests.swift`
- Added the previously missing `levelMeter` assertions (F87): whole-percent rounding plus clamping
  above 1 and below 0. Red-green evidence in the F87 `TICKET_LOG.md` entry.

## Explicitly not changed (and why)

- `AppEntry.swift` — scene wiring only; nothing visual worth touching without F80/F85 scope.
- `AppModel`, `MeetingStore`, `AudioCaptureEngine`, `KeychainStore`, `VocabularyExtractor`,
  dictation controllers, everything in `Sources/WhisperCore` — functional; out of scope by the
  task's own rule.
- The transcript editor's per-keystroke store write — that is open ticket **F40** (functional fix),
  deliberately not smuggled into a presentation pass.
- Existing `withAnimation(.easeInOut)` scroll-to-segment calls — scrolling behaviour, left as-is.
- The `ContentUnavailableView` empty states and all user-facing copy — already right.

## Verification

- `swift build` — clean; `swift test` — **257 tests pass** (baseline before the pass: 257; the new
  assertions extend an existing test).
- New `levelMeter` assertion proven to bite: deliberately wrong expectation fails
  (`Expectation failed: … "Microphone level 42 percent") == "Microphone level 41 percent"`), then
  restored and green.
- `Scripts/build-app.sh` — release build + ad-hoc signing succeed.
- `git diff` reviewed hunk-by-hunk: presentation-only confirmed; touched files are exactly
  `ContentView.swift`, `DictationView.swift`, `DictationOverlay.swift`, new `DesignSystem.swift`,
  the F87 test file, and docs.
- **Not verified here:** the on-screen visual pass and VoiceOver/Dynamic Type spot-check. The GUI
  cannot be launched for testing from an agent session (startup recovery reads the real meeting
  index, which `AGENTS.md` forbids using for tests) — tracked as **F114** in `NEEDS_HUMAN.md`.
  **Update 2026-07-31: F114 passed** — Simon ran the checklist and reported no findings
  (`TICKET_LOG.md` § F114).

---

# Motion opportunity sweep (post-redesign, 2026-07-31)

A restraint-first sweep of the redesigned UI for moments that would *genuinely* benefit from
motion (ticketed as **F116**; originally filed as F115, renumbered after an ID race with a parallel
session's CI ticket). Every candidate was gated on frequency, purpose, speed budget, and
function; most were rejected. Recipes extend the repo's existing vocabulary only —
`Animation.uiSpring` (critically damped, `DesignSystem.swift`), `.smooth(duration: 0.22)`,
`.linear(duration: 0.08)`, and the established Reduce Motion convention (layout springs gate to
`nil`; opacity-only fades may remain).

## Accepted (5)

| # | Location | Today | Purpose | Frequency | Suggested motion |
| --- | --- | --- | --- | --- | --- |
| 1 | `ContentView.swift:1552-1558` (meeting detail) | When `meeting.status` flips to `.completed`, the status card vanishes and the summary + transcript sections appear with no bridge — the app's payoff moment teleports in | Preventing a jarring change / state indication | Occasional (once per transcription) | `.animation(reduceMotion ? nil : .uiSpring, value: meeting.status)` on the detail `VStack`; `.transition(.opacity)` on `statusCard` and the completed-only sections so the swap cross-fades while the spring settles the layout. Under Reduce Motion the opacity cross-fade stays, the layout spring goes |
| 2 | `ContentView.swift:82` (pin), `:130` (delete) | Pinning a meeting teleports its row to the top of the sidebar; deleting one makes the row vanish instantly | Spatial consistency | Occasional | Wrap the mutations at these two call sites in `withAnimation(reduceMotion ? nil : .uiSpring) { … }` so the pinned row glides to its new position and the deleted row collapses. Call-site wrapping (not `.animation` on the `List`) guarantees search filtering stays instant |
| 3 | `ContentView.swift:1605-1608` (summary section) | After a multi-second Claude wait, `ProgressView` → `summaryBody` swaps instantly | State indication (payoff after a wait) | Occasional–rare | `.transition(.opacity)` on `summaryBody`, `.animation(reduceMotion ? nil : .uiSpring, value: isSummarizing)` scoped to the section container — the card fades in as the spring grows the layout. No bounce; the moment earns a beat, not a show |
| 4 | `ContentView.swift:1408,1462,1481,1578` (vocabulary) | Term rows appear/vanish instantly on add, batch import, sheet-accept, and remove | Preventing a jarring change | Occasional | Wrap the four `store.addVocabulary`/`removeVocabulary` call sites in `withAnimation(reduceMotion ? nil : .uiSpring)`. Batch imports animate as one layout change — deliberately **no stagger** |
| 5 | `ContentView.swift:806-820` (preflight test sheet) | The sheet's recording → analyzing → result phases hard-swap inside a fixed frame | Preventing a jarring change | Occasional–rare | `.transition(.opacity)` per phase view + `.animation(reduceMotion ? nil : .uiSpring, value: phaseKey)` where `phaseKey` is a lightweight `Int` discriminant of `model.preflightTest` (the enum carries associated values). Cross-fade only — the sheet frame is fixed, nothing should slide |

## Rejected (with the gate question that killed each)

- `ContentView.swift:36-49,77` — animating sidebar rows as **search filtering** adds/removes them.
  **Rejected: frequency/function — rows change per keystroke while the user is scanning; motion
  hinders.**
- `ContentView.swift:989,1010` — the **"Someone is speaking" label and live meters**.
  **Rejected: function — 15 Hz live feedback must track 1:1; the existing 0.08 s linear fill is
  already the ceiling. Springs or text transitions here would lag the signal.**
- `DictationOverlay.swift:24-28` — an **entrance animation for the dictation pill** on hotkey press.
  **Rejected: frequency + purpose — push-to-talk readiness feedback, tens of times/day; any
  entrance delay undermines "it's listening" certainty. (The in-place phase cross-fade already
  shipped in F113.)**
- `ContentView.swift:2439-2470` — more motion on **transcript segment rows** (entrances, slides).
  **Rejected: function — a reading surface; the existing 0.22 s active-highlight fade (`:2564`) is
  the correct maximum.**
- `ContentView.swift:128-141` — replacing the delete **confirmation dialog with a hold-to-confirm
  fill**. **Rejected: purpose — macOS's `confirmationDialog` is the platform-familiar safeguard;
  a web-style hold gesture solves no gap here.**

## Verdict

Post-F113 the app is close to right: continuous feedback is linear, state changes spring without
overshoot, and motion already respects Reduce Motion. What remains is a handful of *teleporting
state* seams, not a style gap. The single highest-leverage item is **#1** — transcription
completing is the product's payoff moment and currently the most jarring cut in the app. Items
2–5 are small, same-vocabulary refinements; nothing here justifies new tokens, bounce, or stagger.

## Implementation notes (F116, 2026-07-31)

An adversarial verification workflow over the implementation diff confirmed two defects in the
recipes as written above; both were fixed before the close:

1. **The recipe snippets contradicted their own prose on Reduce Motion.** A bare
   `.transition(.opacity)` never fires when the transaction animation is gated to `nil`, so the
   promised "the opacity cross-fade stays, the layout spring goes" was unachievable as coded. Fix:
   `AnyTransition.gentleFade(reduceMotion:)` in `DesignSystem.swift` — the transition carries its
   own animation (`.uiSpring` normally, `.linear(duration: 0.2)` under Reduce Motion), so seams 1,
   3, and 5 always cross-fade and only layout movement is dropped. Seams 2 and 4 are pure layout
   (no fade to preserve) and correctly stay instant under Reduce Motion.
2. **Seam 5's "the sheet frame is fixed, nothing should slide" premise was false** — only the
   width is fixed, and the conditional phase views were `VStack` siblings, so a cross-fade would
   transiently stack them and bounce the sheet height. Fix: the phase container is a `ZStack`
   (outgoing/incoming phases overlay in place) and the height change settles with the same spring —
   instant under Reduce Motion.

A second, fix-focused verification round returned four residual observations; disposition, recorded
here for the F117 manual pass to arbitrate:

- Two claims (seams 1 and 3 "hold their layout slot during the fade, then snap unanimated when the
  removal transition completes") assume a transition-layout model that contradicts established
  SwiftUI behavior — a transitioning-out view renders at its pre-removal frame while sibling
  reflow animates *concurrently* with the transaction (this is the mechanism behind every animated
  list removal). Expected behavior: the reflow springs while the outgoing view fades in place,
  with a brief overlap. **Not fixed; if the F117 eyeball pass sees a snap or stacking at the
  status-card → transcript swap or the spinner → summary swap, reopen.**
- Two observations about the preflight sheet height on shrinking phase changes (taller outgoing
  phase ghost briefly overflowing / instant resize under Reduce Motion while the 0.2 s fade
  completes) are transient sub-half-second cosmetic artifacts inherent to a cross-fade between
  different-height views; the verifier itself judged the Reduce Motion case "consistent with the
  documented design, not a blocker." **Accepted.**
