# Ticket board

**The rules for this board — how to file, claim, close, and log tickets, plus the ID scheme, status
vocabulary, definition of done, and the ticket template — live in [`../AGENTS.md`](../AGENTS.md).
Read them before touching this file.** This file holds **open** work only; closed tickets move to
[`TICKET_LOG.md`](TICKET_LOG.md), and tickets blocked on a human action or decision move to
[`NEEDS_HUMAN.md`](NEEDS_HUMAN.md).

**Next free ID: `F93`.**

---

# Open tickets

### F25 — A shipped helper-script fix does not reach disk until its engine is selected

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** dictation
- **Filed:** 2026-07-30 by Claude Code (review of `e9bca61`)

**Problem.** `DictationController.ensureHelperInstalled()`
(`Sources/WhisperMeet/Dictation/DictationController.swift:209`) syncs only the *currently selected*
engine's helper from the app bundle. After F24 shipped in `64455ec`, the installed
`Runtime/whisper_dictate_server.py` on this machine — which has Qwen selected — stayed at the old
hash `80e86bdaf487` while the bundle carried the fixed `a1d671e3e6da`.

**Impact.** Not a correctness bug today: the sync runs at `DictationController.swift:152` *before*
the replacement engine is constructed, so the fixed helper is always on disk before it is used. But
on-disk state does not reflect the shipped build, which makes diagnostics and manual inspection
misleading, and it means a helper fix is one user action away from mattering rather than applied on
update.

**Reproduced 2026-07-30 while fixing F29.** `Scripts/bench/dictation-ab.py` drives the *installed*
helpers, so it hit the stale copy and failed exactly as F24 did —
`turbo: helper never reported ready. / Detected language: English` — until the bundle copy was
synced by hand. This is no longer only a tidiness concern: any tool or diagnostic that reads the
installed runtime sees pre-fix code.

**Proposed fix.** Sync both engines' helpers on launch (or whenever the bundle version changes)
rather than only the selected one. Cheap — a content comparison and a small file write.

**Verification.** Install a build whose Whisper helper differs from the runtime copy while Qwen is
selected; assert the runtime copy matches the bundle after launch without switching engines.

### F26 — Dictation diagnostics go stale when the model is changed

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** ui
- **Filed:** 2026-07-30 by Claude Code (review of `e9bca61`)

**Problem.** `DictationView` refreshes `diag` on `onAppear`, on the Refresh button, and when a
self-test finishes (`Sources/WhisperMeet/DictationView.swift:38,60,90`) — but not when
`dictation.selectedEngine` changes. The model picker lives in `SettingsView`, a separate window.

**Impact.** Changing the recognition model in Settings leaves the Dictation tab showing the previous
engine's rows — including the `"\(diag.engineName) runtime"` label and an Install/Repair button that
targets the wrong runtime — until the user presses Refresh.

**Proposed fix.**
`.onChange(of: dictation.selectedEngine) { _, _ in diag = dictation.diagnostics() }`.

**Verification.** Not unit-testable (SwiftUI view; the `WhisperMeet` target has no test suite).
Verify manually with both windows open, and say so explicitly in the log.

### F30 — Qwen alignment failure silently drops every timestamp

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** transcription
- **Filed:** 2026-07-30 by Claude Code (two-axis review, both axes)

**Problem.** `PRODUCT_SPEC.md:18` requires "editable **timestamped** transcript segments", and `:27`
requires failures surfaced "in plain language". `QwenAlignedTranscript.swift` returns `[]` at five
guard sites (`:24,30,36,39,51`) — mapping is all-or-nothing, so a single mismatch anywhere drops
*every* timestamp. `AppModel.apply(result:to:)` (`AppModel.swift:965`) then stores untimestamped
plain text. The only trace is an `os.Logger` line (`QwenASRClient.swift:143-148`), which the user
never sees. `PRODUCT_SPEC.md` was edited in this same range but line 18 was left untouched.

**Impact.** A Qwen meeting can silently produce a transcript with no timestamps — no seek, no
playback sync — and the user is given no reason why.

**Proposed fix.** Surface the warning in the UI, and consider partial alignment (keep the sentences
that did map) instead of all-or-nothing. Amend `PRODUCT_SPEC.md:18` to state the documented
fallback.

**Verification.** Force an alignment mismatch; assert the user-visible explanation appears and that
`PRODUCT_SPEC.md` matches actual behaviour.

### F31 — Qwen meeting transcription reports no progress or ETA

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** transcription
- **Filed:** 2026-07-30 by Claude Code (two-axis review, spec)

**Problem.** `QwenASRClient.swift:118-119` emits only `.preparing` / `.loadingModel` and never
`.transcribing` with a fraction. `ContentView.swift:1596-1601` therefore shows "Loading the
recognition model…" with an indeterminate bar for the entire run.

**Impact.** A one-hour Qwen meeting looks hung. The "transcription progress + ETA" delivered in
Round 0 (`ROADMAP.md`) silently does not apply to the newer engine.

**Verification.** A long Qwen run advances a determinate bar.

### F32 — "Original language only" is unenforced and untested on the Qwen path

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** transcription
- **Filed:** 2026-07-30 by Claude Code (two-axis review, spec)

**Problem.** `PRODUCT_SPEC.md:16` forbids automatic translation. Whisper enforces it structurally by
pinning `--task transcribe`. Qwen has no equivalent: `Scripts/qwen_transcribe.py:74-78` passes a
language name into the model call, and nothing in the codebase asserts the output language matches
the input.

**Impact.** A non-negotiable invariant rests on model behaviour rather than on an enforced contract.
Upstream drift would be silent.

**Evidence it currently holds.** All ten `Scripts/bench/clips` returned original-language text on
2026-07-30 (en/zh/code-switch, zero error). That is empirical, not structural, and the corpus is
synthetic.

**Verification.** A regression test that fails if a Mandarin clip comes back in English.

### F33 — Installer crash recovery is only reachable from tests

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** recovery
- **Filed:** 2026-07-30 by Claude Code (two-axis review, spec)

**Problem.** `Scripts/setup-qwen-asr.sh` gates its recovery branch on `QWEN_INSTALL_RECOVERY_ONLY`
(`:23`, `:99`). The only caller is `Tests/WhisperCoreTests/QwenInstallerRecoveryTests.swift:76` —
the app never invokes it.

**Impact.** `PRODUCT_SPEC.md:29-30` promises the previous runtime is preserved on failure. That
holds only within a single install process. After a force-quit mid-install, a ~4 GB backup directory
is orphaned and Qwen reports "not installed" until the user manually reinstalls.

**Verification.** Kill an install mid-run; on next launch the backup is reclaimed or removed without
user action.

### F40 — Transcript Edit view double-writes the whole meetings index on every keystroke

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** ui
- **Filed:** 2026-07-30 by Claude Code (fix sweep, verified)

**Problem.** The transcript editor binding's setter calls
`store.update(id:) { $0.transcriptText = value }` on every keystroke
(`Sources/WhisperMeet/ContentView.swift:1709-1712`). `MeetingStore.update` runs on `@MainActor` and
unconditionally calls `persistMeetings()` (`MeetingStore.swift:209-213`), which JSON-encodes the
ENTIRE `meetings` array and performs a crash-safe backup-then-primary double write. There is no
debounce/coalescing.

**Impact.** For a large library or long transcript, editing re-serializes and writes megabytes to
disk twice per keystroke on the main thread — typing lag, possible cursor/IME-composition jumps (the
app supports Mandarin), and multiplied disk wear.

**Proposed fix.** Hold the edited text in `@State` and flush to the store on a debounce timer and on
blur/teardown, mirroring `EditableMeetingTitle`'s commit-on-blur pattern.

**Verification.** Count `meetingFiles.save` calls while applying N keystrokes and assert it
coalesces to roughly one write after idle rather than N. Fails before, passes after.

### F52 — `setup-local-whisper.sh` installs the default runtime with no atomic staging/backup

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** build
- **Filed:** 2026-07-30 by Claude Code (fix sweep, verified)

**Problem.** The default meetings runtime is built directly into the live `$runtime_directory/venv`
(`Scripts/setup-local-whisper.sh:25,29`); `pip install --upgrade openai-whisper` uninstalls the old
package before installing the new one, so a failure in that window (network drop, build error, disk
full) leaves the previously-working runtime broken with no rollback. The sibling `setup-qwen-asr.sh`
guards the optional path with a staging dir + backup + atomic rename + restore-on-failure
(`:122-186`); the more-critical default path has none of that.

**Impact.** Re-running the installer to upgrade (or a transient failure during first install) can
leave the user unable to transcribe any meeting until a successful re-run. Recordings are untouched
(recording-first invariant holds); recoverable by re-running.

**Proposed fix.** Build into a staging venv, verify `venv/bin/whisper --help`, then swap it in
atomically, keeping the prior venv as a restore-on-failure backup — the pattern `setup-qwen-asr.sh`
already uses.

**Verification.** From a known-good venv, force the pip upgrade to fail (unreachable index) and
assert the pre-existing `venv/bin/whisper --help` still exits 0 after the script fails. Fails
before, passes after.

## Reachability wiring — filed 2026-07-31

Each ticket wires an already-shipped, WhisperCore-tested core to a user-triggerable surface. These
are the deferred user-facing halves of the F55–F77 feature batch, filed under the new **Reachability**
definition-of-done rule; the source log entry cross-references each. (Remove this header when its
last ticket closes.)

### F79 — Wire the recording-health report into stop → store → meeting detail (delivers F58)

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** meetings
- **Filed:** 2026-07-31 by Claude Code (Opus 4.8)

**Problem.** F58 shipped and tested `RecordingHealthReport` + `RecordingHealthMonitor.report()`
(`Sources/WhisperCore/RecordingHealthMonitor.swift:87,211`; `RecordingHealthReportTests.swift`), but
nothing calls it. `AudioCaptureEngine.stop()` (`Sources/WhisperMeet/AudioCaptureEngine.swift:200-265`)
never calls `report()` and `RecordingArtifact` has no health field, so the fold is discarded before
`defer { reset() }` (`:205`) nils the monitor; `AppModel.stopRecording` (`AppModel.swift:480-487`)
builds the `MeetingRecord` without a `healthReport`, so `MeetingRecord.healthReport`
(`MeetingStore.swift:63`) is always nil; `MeetingDetailView.body` (`ContentView.swift:1467-1484`)
never reads it.

**Impact.** A meeting that recorded badly (no system audio, long mic stalls, clipping) shows no
explanation, so the user blames the model for a capture problem. The trust diagnostic F58 built is
invisible in the running app.

**Proposed fix.** Add `healthReport: RecordingHealthReport?` to `RecordingArtifact`; capture
`healthMonitor?.report()` in `stop()` before the deferred reset and carry it into the artifact
(~`:258`); pass `artifact.healthReport` into the `MeetingRecord` init (`AppModel.swift:480`); render a
one-line, channel-level advisory in `MeetingDetailView` after `statusCard` (`ContentView.swift:1472`)
when `worstStatus != .good`. Advisory-only; never speaker identity.

**Verification.** Core fold already covered by `RecordingHealthReportTests`. The persistence hop is
headless-testable in `WhisperMeetTests` (inject a recorder whose `stop()` returns an artifact with a
known report; assert `store.meeting(id:)?.healthReport`). The advisory is SwiftUI with no view harness
— manual: `Scripts/build-app.sh`, record with system audio muted so `.systemAudioNotDetected` fires,
stop, open the meeting, confirm the advisory appears (and none for a clean recording).

### F80 — Render the menu-bar recording controls from the tested presentation core (delivers F62)

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** ui
- **Filed:** 2026-07-31 by Claude Code (Opus 4.8)

**Problem.** `MenuBarRecording.make(...) -> MenuBarRecordingPresentation`
(`Sources/WhisperCore/MenuBarRecording.swift:17-48`; `MenuBarRecordingTests.swift`) is never rendered.
The only `MenuBarExtra` scene (`Sources/WhisperMeet/AppEntry.swift:30-32`) renders `DictationMenu`
(`:51-63`) — Quick Dictation toggle, Settings, Quit only. No file under `Sources/WhisperMeet`
references `MenuBarRecording`, so the promised menu-bar recording controls do not exist.

**Impact.** With the main window minimized, a user cannot start/stop a recording, drop a marker, or
see live "Recording MM:SS" from the menu bar. No data is at risk (recording stays controllable from
the main window); the menu-bar convenience/awareness surface is simply absent. This is the **preferred**
background-awareness surface — see F89 (the HUD overlap), which is subordinate to this.

**Proposed fix.** In `AppEntry.swift`, pass `model` into the menu-bar view and drive it from
`MenuBarRecording.make(...)` (derive `isRecording`/`isStopping`/`elapsedSeconds` from
`AppModel.recordingState`; pass `isMicrophoneBusy` `:203`, `hasActiveTranscription` `:218`). Map the
presentation's enablement/titles to `startRecording()` `:411`, `stopRecording(title:)` `:472`,
`addLiveMarker()` `:551`, and `cancelRecording()` `:537` behind confirmation. Keep the dictation items
below a Divider. No core change.

**Verification.** Decision logic already covered by `MenuBarRecordingTests`. Scene wiring is SwiftUI
with no harness in `WhisperMeetTests` — manual: `Scripts/build-app.sh`; hide the main window; confirm
the menu shows "Not recording" (Start enabled, others disabled); Start → status ticks and actions
enable; Add Marker drops a marker; Cancel prompts; Stop & Transcribe finalizes. Cross-check the
menu-bar state agrees with the main window.

### F81 — Wire the summary-style picker into the summary UI and AppModel.summarize (delivers F63)

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** ui
- **Filed:** 2026-07-31 by Claude Code (Opus 4.8)

**Problem.** `SummaryStyle` (`Sources/WhisperCore/MeetingSummarizer.swift:53`) and the style-threaded
`summarize(transcript:language:style:)` / `ClaudeSummarizer.systemPrompt(language:style:)`
(`ClaudeSummarizer.swift:83,102`) are tested, but no app code selects a style.
`AppModel.summarize(id:)` (`AppModel.swift:868` → `performSummarization` → `:899`) calls the 2-arg
convenience defaulting to `.balanced`, and `summarySection` (`ContentView.swift:1504`, button `:1515`)
has no picker. `SummaryStyle` has zero references in `Sources/WhisperMeet`.

**Impact.** `.brief`/`.detailed`/`.actionItemsFocused` are unreachable dead code; everyone gets the
balanced style. A stand-up user wanting action-items-only, or a one-line brief, cannot get it.

**Proposed fix.** Thread a `SummaryStyle` through `summarize(id:)`/`performSummarization` into the
3-arg `summarize(...style:)` at `AppModel.swift:899`; add a compact `Picker` over `SummaryStyle.allCases`
in `summarySection` bound to `@AppStorage`, next to the Summarize/Re-summarize button. Same upload
path, schema, and do-not-translate clause (already asserted per style).

**Verification.** Core threading covered by `ClaudeSummarizerTests`. Wiring is SwiftUI with no harness,
and `performSummarization` constructs `ClaudeSummarizer` inline (`:897`) with no summarizer seam — do
not fake a test. Optional automated coverage: inject a `MeetingSummarizer` seam and assert the chosen
style reaches `summarize(...style:)`. Manual: save an API key, Summarize with "Brief" (markedly
shorter), Re-summarize with "Action items" (task-focused).

### F82 — Add the glossary-correction review sheet and call site (delivers F65)

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** transcription
- **Filed:** 2026-07-31 by Claude Code (Opus 4.8)

**Problem.** `GlossaryCorrector.corrections(vocabulary:segments:)`
(`Sources/WhisperCore/GlossaryCorrector.swift:24`; `GlossaryCorrectorTests.swift`) is never invoked —
`grep GlossaryCorrector Sources/WhisperMeet` is empty. No toolbar action runs the matcher and no
review sheet (mirroring `VocabularySuggestionSheet`, `ContentView.swift:1925`, hosted at `:1493`)
exists.

**Impact.** Users cannot correct proper-noun misrecognitions toward saved vocabulary — most acute on
Qwen, which does not consume Whisper's `--initial_prompt`, so there is currently **no** in-app path to
normalize e.g. "cooper netties" → "Kubernetes" in a Qwen transcript. The tested matcher delivers zero
value while unwired.

**Proposed fix.** Add a "Correct toward Vocabulary" action near "Suggest Vocab"
(`ContentView.swift:~1744`); call `GlossaryCorrector.corrections(...)`; if non-empty present a
`GlossarySuggestionSheet` (per-row toggle, Cancel/Apply). On Apply, mutate only accepted segments via
`store.update(id:)` — WAV untouched; never auto-apply; guard when `isTranscriptEdited`. Consider a pure
`GlossaryCorrector.apply(_:to:)` helper so the apply step is unit-testable.

**Verification.** Matcher covered by `GlossaryCorrectorTests`; if an apply-helper is added, unit-test
it in WhisperCore. Sheet is SwiftUI with no harness — do not fake a view test. Manual: add "Kubernetes"
to vocabulary, open a meeting whose segment says "cooper netties", run the action, confirm one proposal
"cooper netties" → "Kubernetes", accept, confirm the segment updates in place and `meeting.wav` is
unmodified.

### F84 — Wire tag click-to-filter into the sidebar (delivers F67)

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** meetings
- **Filed:** 2026-07-31 by Claude Code (Opus 4.8)

**Problem.** `MeetingTags.matches(meetingTags:selected:mode:)` (`Sources/WhisperCore/MeetingTags.swift:34`;
`MeetingTagsTests.swift:18-25`) has no user surface. `filteredMeetings` (`ContentView.swift:36-49`)
composes only `MeetingQuery.matches` and never references tags; there is no `selectedTags` state and
the sidebar tag chips (`ContentView.swift:203-213`) are non-interactive `Text`. Tags can be written
(`store.setTags`, `:1449-1457`) and shown, but cannot filter. (Editor + chips + persistence ARE wired;
only the filter is unshipped.)

**Impact.** Users can label meetings but cannot retrieve by label — clicking a tag does nothing, and
tags are excluded from the free-text search fields (`ContentView.swift:46`). The headline
"click-to-filter" axis is absent; tagging only decorates rows.

**Proposed fix.** Add `@State selectedTags: Set<String>` (+ optional `MatchMode`, default `.any`) near
`ContentView.swift:28`; make the chips tappable to toggle membership; AND the tested predicate into
`filteredMeetings` via `MeetingTags.matches(meetingTags: $0.tags ?? [], selected:..., mode:...)`. Empty
selection returns true, so it stacks with free-text search.

**Verification.** `matches` covered by `MeetingTagsTests`. `filteredMeetings` is a private SwiftUI
computed property with no seam — either extract the composition into a pure `MeetingLibraryFilter`
(WhisperCore) and test that a selected tag narrows a fixture, or verify manually: tag one meeting
`budget` and another `hiring`, click `budget`, confirm only that meeting remains, clear, confirm both
return.

### F85 — Wire the command catalog into a Commands menu + Keyboard Shortcuts sheet (delivers F69)

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** ui
- **Filed:** 2026-07-31 by Claude Code (Opus 4.8)

**Problem.** `CommandCatalog` (`Sources/WhisperCore/CommandCatalog.swift:62,76`; `CommandCatalogTests.swift`)
— ⌘R toggle, ⇧⌘M Add Marker, Cancel Recording…, ⌘/ Shortcuts — is never referenced. The App scene
(`Sources/WhisperMeet/AppEntry.swift:9-39`) has no `.commands { }` and there is no shortcuts sheet.

**Impact.** No Commands menu and no app-wide shortcuts: no ⌘R start/stop, no ⌘/ help sheet, Cancel has
no menu presence; ⇧⌘M works only via a local button (`ContentView.swift:424`). The single tested source
of shortcut truth cannot prevent collisions because nothing consumes it.

**Proposed fix.** Add `.commands { }` to the `WindowGroup` building a `CommandMenu` from
`CommandCatalog.all`: derive each `.keyboardShortcut` from `keyEquivalent` + a `CommandModifiers`
mapping and `.disabled(!enablement.isEnabled(state))` from an observable `AppCommandState`. Route ids
to existing actions (`startRecording`/`stopRecording` `:411/:472`, `addLiveMarker` `:551`,
`cancelRecording` `:537`), and add a `KeyboardShortcutsView` sheet rendering `displayShortcut(for:)`.
Reconcile the hand-wired ⇧⌘M (`ContentView.swift:424`) so it is not double-registered.

**Verification.** `CommandCatalogTests` stays green; no `.commands{}`/sheet harness exists — do not
fake a view test. Manual: confirm a Recording menu with ⌘R and ⇧⌘M (enabled only while recording),
Help ▸ Keyboard Shortcuts (⌘/) lists every entry with its shortcut, ⌘R toggles recording, and no
"ambiguous shortcut" console warning.

### F86 — Add a Settings "Export diagnostics…" action for the diagnostics bundle (delivers F70)

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** ui
- **Filed:** 2026-07-31 by Claude Code (Opus 4.8)

**Problem.** `DiagnosticsBundleBuilder.json` over `DiagnosticsInput`
(`Sources/WhisperCore/DiagnosticsBundleBuilder.swift:52,6`; `DiagnosticsBundleBuilderTests.swift`) has
zero callers. `SettingsView` (`ContentView.swift:1049-1248`) has no "Export diagnostics…" control and
`AppModel` never maps `store.meetings`/`store.vocabulary` into a `DiagnosticsInput`.

**Impact.** A user hitting a problem cannot export the privacy-safe structural JSON the core produces,
so support relies on manual descriptions. The tested guarantee (ids/counts/sizes but never transcript
text, summaries, vocabulary terms, or absolute paths) delivers no real value while unwired.

**Proposed fix.** Add an `AppModel` mapping method (`MeetingRecord` → `DiagnosticsInput.Meeting`:
id, epoch createdAt, duration, status, languageCode, segment/marker counts, `recordingBytes` via
`FileManager`, errorMessage; transcript/summary passed through but never emitted) + a Settings
"Export diagnostics…" button writing via `NSSavePanel`, mirroring `saveExport` (`ContentView.swift:1900`).
Keep the mapping in a testable seam, not inline in the view.

**Verification.** Exclusion/determinism covered by `DiagnosticsBundleBuilderTests`. Put the mapping in
a seam and add a `WhisperMeetTests` case: a `MeetingRecord` with sentinel transcript/summary/vocab →
mapping + `json` → output has counts/ids but not the sentinels (fails before the seam, passes after).
Button is SwiftUI — manual: export, confirm the file lists only structural fields and grep finds none
of your transcript/vocab strings and no absolute paths.

### F87 — Attach the remaining accessibility labels and Dynamic Type (delivers F71)

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** ui
- **Filed:** 2026-07-31 by Claude Code (Opus 4.8)

**Problem.** `AccessibilityPhrase` (`Sources/WhisperCore/AccessibilityPhrase.swift`) is 1/4 wired:
`meetingRow` is attached (`ContentView.swift:217`), but `recordButton` (`:13`), `marker` (`:18`), and
`levelMeter` (`:22`) are not attached to the record button (`ContentView.swift:270-285`), marker rows
(`:709-716`), or the meter (a hardcoded label sits at `:967`). Transcript/timer fonts use fixed point
sizes (`:246,784,794,816,860`) that ignore Dynamic Type.

**Impact.** VoiceOver users do not hear the tested state-aware labels (the record button never
announces "Recording controls unavailable"; markers read as unlabeled; the meter reads a generic
string), and low-vision users get no scaling on the 58pt title / 48pt timer. Operable but materially
less accessible than the tested core already allows.

**Proposed fix.** Attach `recordButton(isRecording:isBusy:)`, `marker(label:offset:)` (with
`.accessibilityElement(children:.ignore)`), and `levelMeter(channel:level:)` at the sites above; add
the missing `levelMeter` assertion to `AccessibilityPhraseTests`; replace fixed `.system(size:)` fonts
with semantic text styles or `@ScaledMetric`.

**Verification.** Phrase functions get WhisperCore unit coverage (add the `levelMeter` red-green). The
wiring has no SwiftUI/accessibility harness — verify manually with Accessibility Inspector / VoiceOver:
record button announces start/stop/unavailable, a marker reads "Marker <label> at MM:SS" as one
element, the meter reads "<channel> level NN percent", and larger-text settings scale the title/timer.

### F88 — Wire the "Second opinion" cross-engine comparison (delivers F73)

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** transcription
- **Filed:** 2026-07-31 by Claude Code (Opus 4.8)
- **Blocked by:** F30 (Qwen timestamps) — the Whisper→Qwen direction needs F30 for meaningful
  time-overlap alignment; Qwen→Whisper and Whisper-large↔turbo can ship first, so the ticket is not
  fully blocked.

**Problem.** `TranscriptComparison.compare(_:_:)` (`Sources/WhisperCore/TranscriptComparison.swift:26`;
`TranscriptComparisonTests.swift`) has no callers — `grep TranscriptComparison Sources/WhisperMeet` is
empty. No "Second opinion" action runs the non-selected engine on the same `meeting.wav` and feeds both
segment arrays into `compare`.

**Impact.** Users cannot cross-check a transcript against the other local engine to see where they
disagree — the trust/verification workflow the core was built for. The feature does not exist for the
user.

**Proposed fix.** Add a "Second opinion" action on a completed meeting: snapshot the non-selected
engine; run it on the existing WAV through the SAME single-run guard
(`beginTranscription`/`pumpTranscriptionQueue`, `AppModel.swift:807,832`) but into a scratch buffer,
never overwriting the stored transcript; call `compare(...)`; present agree/diverge/nonOverlapping
spans in a `ContentView` sheet with per-span replace/keep. Both engines only read the WAV.

**Verification.** Add a `WhisperMeetTests` case asserting a second-opinion run does NOT mutate the
stored transcript and that the single-run guard rejects a concurrent normal transcription. Sheet is
SwiftUI (manual): transcribe with Whisper, "Second opinion", confirm the span sheet, that replace/keep
applies only on confirm, and keeping leaves the transcript byte-for-byte unchanged.

### F89 — Build the compact recording HUD overlay (delivers F74; subordinate to F80)

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** ui
- **Filed:** 2026-07-31 by Claude Code (Opus 4.8)

**Problem.** `RecordingHUD.make(...) -> RecordingHUDState`
(`Sources/WhisperCore/RecordingHUD.swift:19`; `RecordingHUDTests.swift`) has zero callers in
`Sources/WhisperMeet`. No `NonActivatingPanel`-based overlay renders it.

**Impact.** A backgrounded meeting shows no compact always-on HUD (elapsed, status, most-severe
warning). **Overlaps F80** (menu-bar controls): both are background-awareness surfaces. Per F74's own
warning, **if only one is funded, F80 (menu bar) wins** and this should be closed `wontfix`. Kept a
notch below F80 for that reason.

**Proposed fix.** Add a `NonActivatingPanel`-based overlay (mirroring
`Sources/WhisperMeet/Dictation/DictationOverlay.swift`) driven by `RecordingHUD.make(...)`, gated on
`shouldPresent` (recording AND backgrounded). Display-only; reads state, never mutates audio.

**Verification.** State core covered by `RecordingHUDTests`. Overlay is SwiftUI/`NonActivatingPanel`
with no harness — manual: start recording, background the app, confirm the HUD shows elapsed time and
the most-severe warning, and disappears on foreground/stop. First re-confirm F80 is not the chosen
single surface.

### F90 — Add the BackupCoordinator + Settings "Back up library…" action (delivers F75)

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** recovery
- **Filed:** 2026-07-31 by Claude Code (Opus 4.8)

**Problem.** `BackupPlan.compute` / `BackupRetention.prune` / `BackupVerification.succeeded`
(`Sources/WhisperCore/BackupPlan.swift:28,57,71`; `BackupPlanTests.swift`) have no wiring. There is no
`BackupCoordinator` in the tree and `SettingsView` (`ContentView.swift:1049`) has no backup action.
The source root already exists (`MeetingStore.rootDirectory`, `MeetingStore.swift:131`).

**Impact.** Users cannot back up recordings/indexes to a chosen folder from the app. The hash-verified,
retention-aware capability ships as dead code; if the primary disk fails, the recordings — the declared
source of truth — are lost with no in-app backup, undercutting the "be trusted" premise.

**Proposed fix.** Add `Sources/WhisperMeet/BackupCoordinator.swift`: enumerate `rootDirectory` into
`[BackupFile]` (path, size, SHA-256), read destination descriptors, `BackupPlan.compute`, copy `.copy`
items in `Task.detached` with a pre-copy free-space check, verify each via `BackupVerification`, and
`BackupRetention.prune` old destination generations. Add a "Back up library…" button + retention picker
to `SettingsView` (`NSOpenPanel`, `canChooseDirectories`). Only copy from the source; never modify/delete
it.

**Verification.** The coordinator is headless-testable in `WhisperMeetTests` with injected temp
source/dest dirs: unchanged→skip, changed/new→copy, each copy verifies, source bytes untouched,
retention drops only oldest dest generations. Settings button/`NSOpenPanel` have no harness — manual:
"Back up library…", pick an empty folder, confirm files appear; run again, confirm unchanged files
skip; confirm the source Recordings/ folder is byte-for-byte unchanged.

### F91 — Add the EventKit bridge so calendar titles pre-fill (delivers F76)

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** meetings
- **Filed:** 2026-07-31 by Claude Code (Opus 4.8)

**Problem.** `CalendarTitleMatcher.bestTitle(...)` over `CalendarEventSummary`
(`Sources/WhisperCore/CalendarTitleMatcher.swift:17,5`; `CalendarTitleMatcherTests.swift`) has no
caller. `AppModel.stopRecording(title:)` titles from the user field or a timestamp fallback
(`AppModel.swift:478-482`) and captures the start (`:459`) but never queries the calendar; there is no
EventKit bridge mapping `EKEvent` → `[CalendarEventSummary]`.

**Impact.** Users get a generic timestamp title even when the recording clearly matches a known
scheduled event. Convenience only — the auto-title fallback keeps working — so this is a **deliberately
deferred** item: adding EventKit is a new dependency and a privacy-sensitive Calendar permission (an
explicit product choice), which is why it is severity-low and gated on an opt-in.

**Proposed fix.** Add `Sources/WhisperMeet/CalendarTitleProvider.swift`: lazily authorize Calendar
access, fetch events around the recording start, map to `CalendarEventSummary`, and call
`bestTitle(forRecordingStartedAt: <startedAt at AppModel.swift:459>, in:, tolerance: ~15min)` to
pre-fill the title. Gate behind an **opt-in Settings toggle (default off)**; add
`NSCalendarsUsageDescription`. On denied/no-match, silently keep the timestamp title.

**Verification.** Matcher covered by `CalendarTitleMatcherTests`. EventKit needs live permission and
`WhisperMeetTests` has no seam for it — manual: with the toggle ON and access granted, create an event
spanning "now", record, confirm the title pre-fills; with no nearby event, confirm timestamp fallback;
deny access, confirm recording still starts and titles fall back with no error. Optionally inject a
fake provider seam for a headless pre-fill test.

### F92 — Wire per-segment re-run into the transcript segment menu (delivers F77)

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** transcription
- **Filed:** 2026-07-31 by Claude Code (Opus 4.8)
- **Blocked by:** F30 (Qwen timestamps) — the Qwen menu item must wait for F30 (its timestamps are
  dropped, so there is nothing to splice); the Whisper path produces reliable timestamps and can ship
  first, so the ticket is not fully blocked.

**Problem.** `SegmentAudioRange.byteRange` + `TranscriptSegmentSplice.splice`
(`Sources/WhisperCore/SegmentRerun.swift:10,20`; `SegmentRerunTests.swift`) have no callers. The
segment context menu (`Sources/WhisperMeet/ContentView.swift:2438-2445`) exposes only Copy actions —
no "Re-transcribe this segment" — and `AppModel` has no orchestration to read a WAV byte sub-range,
write a temp clip, run the engine, and splice back.

**Impact.** A user who spots a garbled span cannot fix it in place — only re-run the whole meeting or
hand-edit. The quality-review UI (`ContentView.swift:~2085,2371`) flags risky segments but offers no
way to act on them, leaving the review loop open-ended.

**Proposed fix.** Add "Re-transcribe this segment" to the segment menu (`~:2438`) invoking a new
`AppModel` method with the tapped index that computes `SegmentAudioRange.byteRange(...,sampleRate:16000)`,
performs the codebase's first partial WAV read (past the 44-byte header), wraps it via `WAVWriter.wavData`,
runs the snapshot engine under the single-run guard (`activeTranscriptionID`, `:216`), then
`TranscriptSegmentSplice.splice(...)` and persists. Ship Whisper first; gate the Qwen item on F30.
Recording untouched — only a temp clip is written.

**Verification.** Extract the read→temp-clip→run→splice orchestration into an injectable engine seam so
a `WhisperMeetTests` lifecycle test asserts spliced-back segments against a stub without real audio/GUI.
Context menu is SwiftUI (manual until the seam exists): re-transcribe a segment, confirm `meeting.wav` +
`source-tracks.json` are unchanged, the segment updates with ordered neighbouring timestamps, and a
cancel/failure leaves transcript and audio intact and retryable.

### F93 — Quality gate is red: `-warnings-as-errors` build fails on `DiagnosticsBundleBuilder.swift:65`

- **Status:** open
- **Owner:** —
- **Severity:** high
- **Area:** build
- **Filed:** 2026-07-31 by Claude Code (Opus 4.8) / recovery lane

**Problem.** `Scripts/quality-check.sh` step 3 (`swift build --disable-sandbox -c release -Xswiftc
-warnings-as-errors`) fails on the current tree (identical to `origin/main`) with a single error:

```text
Sources/WhisperCore/DiagnosticsBundleBuilder.swift:65:33: error: expression implicitly coerced from 'String?' to 'Any'
```

`DiagnosticsBundleBuilder.json(_:)` builds a `[String: Any]` dictionary; on line 65,
`"errorMessage": meeting.errorMessage ?? ""`, the `??` operator resolves to its `Optional` overload in
the `Any`-typed value position, so the whole expression is typed `String?` and implicitly coerced to
`Any`. The trigger is the `-warnings-as-errors` flag, not release mode — a plain `swift build` and
`swift test` emit this only as a suppressible warning and both pass. (Curiously, the structurally
identical `languageCode ?? ""` on line 60 does not trip; only line 65 does — a type-checker overload
wart, not a difference in the code's shape.)

**Impact.** The whole-repo quality gate is red, and has been since F70 first landed the file
(`03e4694`, 2026-07-30) — its log evidence shows only `swift test` (216 tests) with a `<this commit>`
placeholder, so the release `-warnings-as-errors` step was never run green at close. Every lane is
instructed to run `Scripts/quality-check.sh` and have it pass whole before closing work; that gate
cannot currently pass, so this blocks a clean close for all lanes. **Not a user-facing runtime bug:**
the code runs correctly (`JSONSerialization` accepts the boxed non-nil optional; the F70 test and the
full suite pass at 233 tests with the real structural fields present), so the emitted diagnostics JSON
is unaffected. This is a build-hygiene / gate failure only.

**Cross-lane note.** `DiagnosticsBundleBuilder.swift` is a diagnostics core (shipped by F70; app
wiring tracked by F86), outside the recovery lane's ownership (recovery/integrity/backup). The
recovery lane found this while independently re-running the gate to verify F83, and is filing rather
than fixing per the "if a fix requires another lane's files, stop and file a cross-lane dependency"
rule. Whoever owns diagnostics/build should take it.

**Proposed fix.** Force the non-optional `String` type so `??` selects its non-optional (`T`) overload,
e.g. `"errorMessage": (meeting.errorMessage ?? "") as String,`. (`as Any` — the compiler's own
suggestion — would silence it too but preserves the optional coercion; prefer the `String` cast.)

**Verification.** The exact gate step — `swift build --disable-sandbox -c release -Xswiftc
-warnings-as-errors` — exits non-zero before the fix (evidence above) and must exit 0 after, and the
full `Scripts/quality-check.sh` must then pass whole. No behavior test is needed because output is
already correct and covered by `DiagnosticsBundleBuilderTests`; for a build-hygiene fix, the
failing→passing gate command *is* the red-green evidence. Confirm the `swift test` count does not drop.
