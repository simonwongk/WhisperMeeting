# Ticket board

**The rules for this board — how to file, claim, close, and log tickets, plus the ID scheme, status
vocabulary, definition of done, and the ticket template — live in [`../AGENTS.md`](../AGENTS.md).
Read them before touching this file.** This file holds **open** work only; closed tickets move to
[`TICKET_LOG.md`](TICKET_LOG.md), and tickets blocked on a human action or decision move to
[`NEEDS_HUMAN.md`](NEEDS_HUMAN.md).

**Next free ID: `F93`.**

---

# Open tickets

### F31 — Qwen meeting transcription reports no progress or ETA

- **Status:** blocked
- **Owner:** —
- **Severity:** medium
- **Area:** transcription
- **Filed:** 2026-07-30 by Claude Code (two-axis review, spec)
- **Blocked by:** F101 — the determinate bar needs the Qwen helper (`Scripts/qwen_transcribe.py`,
  outside the transcription lane's `Sources/` ownership) to emit per-chunk progress. Verified
  2026-07-31 by the transcription lane: the helper emits **zero** stdout/stderr during a real run,
  so there is nothing for `QwenASRClient` to stream-parse until the helper is changed.

**Problem.** `QwenASRClient.transcribe` (`Sources/WhisperCore/QwenASRClient.swift:117-118`) emits only
`.preparing` / `.loadingModel` and never `.transcribing` with a fraction, and its `run(...)`
(`:174`) reads the subprocess output only at EOF (`readDataToEndOfFile`) rather than streaming it.
`transcriptionProgressBar` (`Sources/WhisperMeet/ContentView.swift`) therefore shows an indeterminate
bar labelled "Loading the recognition model…" for the entire run.

**Impact.** A one-hour Qwen meeting looks hung. The "transcription progress + ETA" delivered in
Round 0 (`ROADMAP.md`) silently does not apply to the newer engine.

**Root of the block (verified 2026-07-31).** Unlike the Whisper CLI — whose `tqdm` bar streams to
stderr and is parsed live (`LocalWhisperClient.run`, `WhisperProgressParser`) — the Qwen helper runs
`asr.generate(...)` with `verbose` defaulting to `False`, and mlx-audio 0.3.1 only shows its
"Processing chunks" `tqdm` bar when `verbose and len(chunks) > 1`
(`…/mlx_audio/stt/models/qwen3_asr/qwen3_asr.py:1108-1111`). So the helper produces no parseable
progress today. The Swift-side streaming (my lane) is ready to build the moment the helper emits
something; the helper change is the blocker.

**Verification.** A long Qwen run advances a determinate bar.

### F100 — Qwen alignment is all-or-nothing; consider keeping the sentences that did map

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** transcription
- **Filed:** 2026-07-31 by transcription (follow-up from F30)

**Problem.** `QwenAlignedTranscript.segments` (`Sources/WhisperCore/QwenAlignedTranscript.swift:24,30,36,39,51`)
returns `[]` at every guard site, so a single unreconcilable sentence discards the timestamps of
*every* sentence — including the ones that matched exactly. F30 made this state visible (the meeting
now carries a plain-language `alignmentWarning`) but did not change the all-or-nothing mapping.

**Impact.** A meeting where alignment fails on one sentence loses seek/playback-sync for the whole
transcript even though most sentences aligned cleanly. Lower value than F30's silent-drop fix, which
is why it was deferred rather than bundled.

**Proposed fix.** Emit the sentences that assembled exactly as timestamped segments and leave only the
unmatched tail untimestamped, rather than dropping all. Sentences are only appended after an exact
key match, so kept segments never risk dropped/misattributed words. Keep the F30 warning whenever any
sentence is left untimestamped. Weigh against a mixed timestamped/untimestamped transcript being more
confusing than none — spike before committing.

**Verification.** A `QwenAlignedTranscript` test: a two-sentence transcript whose second sentence does
not reconcile yields one timestamped segment for the first sentence (today it yields zero). Fails
before, passes after.

### F101 — Qwen helper must emit per-chunk progress so a meeting run can show a determinate bar

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** build
- **Filed:** 2026-07-31 by transcription (cross-lane dependency for F31)

**Problem.** F31 needs a determinate progress bar for a long Qwen meeting, but the Qwen helper emits
no progress signal to parse. `Scripts/qwen_transcribe.py:129` calls `asr.generate(audio,
language=…, chunk_duration=240.0, min_chunk_duration=0.1)` with `verbose` defaulting to `False`.
In the pinned **mlx-audio 0.3.1** source, `Qwen3ASR.generate` chunks the audio and iterates
`tqdm(chunks, desc="Processing chunks", disable=not verbose or len(chunks) == 1)`
(`…/site-packages/mlx_audio/stt/models/qwen3_asr/qwen3_asr.py:1078,1108-1111`), so **no bar is
written unless `verbose=True` and there is more than one chunk**. A `stream=True` path also exists
that yields a `StreamingResult` per chunk (`qwen3_asr.py:1180,1244-1278`). Verified empirically on
2026-07-31: a real helper run over `Scripts/bench/clips/en2.wav` produced **zero** stdout/stderr.

**Why cross-lane.** The helper lives under `Scripts/`, outside the transcription lane's `Sources/`
ownership. The Swift half (streaming `QwenASRClient.run` + a Qwen progress parser mirroring
`LocalWhisperClient.run` / `WhisperProgressParser`) is in the transcription lane and is ready to build
as soon as a stable progress format exists — but it must not guess the format before the helper emits
one.

**Proposed fix (coordinate the two halves).**
1. **Helper (`Scripts/` lane):** make the per-chunk progress observable on a stream the client reads.
   Lowest-risk is `verbose=True` so mlx-audio's own "Processing chunks" `tqdm` bar streams to stderr
   (matching the Whisper precedent of parsing `tqdm`); note it is suppressed for single-chunk
   (short) runs, which is acceptable since those finish quickly. A more explicit and single-chunk-safe
   alternative is to switch to `stream=True` and print one dedicated progress line per yielded chunk
   (e.g. a stable `QWEN_PROGRESS <done>/<total>` token on stderr). Re-verify the chosen call against
   the pinned mlx-audio 0.3.1 source per AGENTS.md and record the citation.
2. **`QwenASRClient` (transcription lane):** replace `readDataToEndOfFile` with the streaming
   `AsyncStream<Data>` + `readabilityHandler` pattern already used by `LocalWhisperClient.run`, add a
   `QwenProgressParser` (unit-tested against captured helper output), and emit `.transcribing`
   `LocalTranscriptionProgress` with `fractionCompleted` (done/total) and an ETA.

**Verification.** With the helper change in place, a multi-chunk Qwen run advances a determinate bar
(fraction increases per completed chunk) and the label reads "Transcribing locally…"; a
`QwenProgressParser` unit test maps a captured progress line/`tqdm` frame to the expected fraction
(fails before, passes after).

### F33 — Installer crash recovery is only reachable from tests

- **Status:** in-progress
- **Owner:** runtime
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

### F112 — 42 closed log entries carry the `<this commit>` placeholder instead of a real SHA

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** docs
- **Filed:** 2026-07-31 by Claude Code (runtime lane)

**Problem.** `grep -c '<this commit>' docs/TICKET_LOG.md` returns **42**: that many closed entries
were logged with the literal placeholder in their **Commits** field (e.g. F28 at
`docs/TICKET_LOG.md:222`). `AGENTS.md` (Definition of done → Traceable commit) states the placeholder
"is never an acceptable final value; if the SHA is unknown at write time, amend the entry in the
following commit." These were never amended.

**Impact.** The evidence log cannot be traced to the commit that closed each of those tickets from
the log alone. The information is **recoverable** (`git log --grep=F28` → `2cea357`), so nothing is
lost, but the log — the repo's primary evidence artifact — silently fails its own traceability rule
42 times.

**Proposed fix — needs a human ruling first.** `AGENTS.md` also makes the log **append-only**
("Never edit or delete an existing entry"), with the *only* sanctioned edit being a Gaps
cross-reference append. Backfilling these SHAs would edit closed entries, which the append-only rule
forbids. Resolving this therefore requires Simon to decide whether to relax append-only for a
one-time SHA backfill (each SHA recovered via `git log --grep=F<n>`), or to accept the placeholders
as a frozen historical artifact and instead tighten the close checklist so no future entry ships with
`<this commit>`. **Do not edit the closed entries without that ruling.**

**Verification.** After the ruling: either `grep -c '<this commit>' docs/TICKET_LOG.md` returns 0
(backfilled), or a documented decision records the placeholders as accepted history and a guard
prevents new ones.

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
