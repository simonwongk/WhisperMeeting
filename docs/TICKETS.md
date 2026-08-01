# Ticket board

**The rules for this board — how to file, claim, close, and log tickets, plus the ID scheme, status
vocabulary, definition of done, and the ticket template — live in [`../AGENTS.md`](../AGENTS.md).
Read them before touching this file.** This file holds **open** work only; closed tickets move to
[`TICKET_LOG.md`](TICKET_LOG.md), and tickets blocked on a human action or decision move to
[`NEEDS_HUMAN.md`](NEEDS_HUMAN.md).

**Next free ID: `F130`.**

---

# Open tickets

### F125 — Record screen is not scrollable; the Stop button can be unreachable while recording

- **Status:** in-progress
- **Owner:** Claude Code (Fable 5, apple-design redesign session 2026-07-31)
- **Severity:** high
- **Area:** ui
- **Filed:** 2026-07-31 by Claude Code, reported by Simon with a screenshot (F124 feel pass)

**Problem.** `RecordMeetingView.body` is a fixed `VStack` with top/bottom `Spacer()`s and no
`ScrollView` (`Sources/WhisperMeet/ContentView.swift:252` area). While recording, the content
(hero + timer + live meter + markers + health card + buttons + consent note) exceeds the window
height at common sizes; the `VStack` overflows and clips at BOTH edges — Simon's screenshot shows
the hero orb sliced at the top and the red **Stop & Transcribe** button cut off at the bottom with
no way to scroll to it.

**Impact.** The primary way to end a recording can be unreachable (no menu command exists — F85
is still unwired). The user must resize the window to regain the button. High severity: blocks the
core flow at realistic window sizes.

**Proposed fix.** Wrap the content in `GeometryReader` + `ScrollView`, drop the two `Spacer()`s,
and give the inner `VStack` `.frame(minHeight: geometry.size.height)` so it stays vertically
centered when it fits and scrolls when it doesn't.

**Verification.** Build/test green; manual — shrink the window to `minHeight` while recording and
confirm the Stop button is always reachable by scrolling; content still centers on a tall window.

### F126 — Sidebar search field renders on top of the window controls

- **Status:** in-progress
- **Owner:** Claude Code (Fable 5, apple-design redesign session 2026-07-31)
- **Severity:** medium
- **Area:** ui
- **Filed:** 2026-07-31 by Claude Code, reported by Simon with a screenshot (F124 feel pass)

**Problem.** `.searchable(text:placement:.sidebar,…)` (`Sources/WhisperMeet/ContentView.swift:100`
area) renders the search field pinned at the very top of the sidebar **above** the traffic-light
window controls, overlapping the title-bar row (Simon's screenshot: search field at y≈0 spanning
the sidebar, window controls pushed to a second row below it). Pre-existing (the placement predates
F113), surfaced by the feel pass.

**Impact.** The sidebar header area reads as broken and the search field crowds the window
controls.

**Proposed fix.** Move the search to `placement: .toolbar` — the macOS-conventional position
(Finder, Mail) in the unified toolbar, away from the fragile sidebar/title-bar region. Same
binding, same query syntax, same prompt.

**Verification.** Build/test green; manual — the search field sits in the window toolbar, the
traffic lights are back in their normal single title-bar row, and `lang:zh`-style queries still
filter the sidebar list.

### F121 — Serial quality gate can still hang inside the Swift test helper

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** build
- **Filed:** 2026-07-31 by Codex /root (new-build review)

**Problem.** The first post-F120 `Scripts/quality-check.sh` run completed its build and started the
serial Swift suite, then stopped emitting output for more than a minute. Process inspection showed
only `swiftpm-testing-helper --no-parallel` alive, with no child test subprocess. Interrupting that
run left no helper processes; an immediate identical gate retry completed all 259 tests in 5.429 s.
This is a fresh recurrence after F115 claimed the constrained-runner hang class fixed.

**Impact.** A nondeterministic local/CI hang can withhold the quality signal and waste the full job
timeout even though the candidate is healthy. It also weakens F115's claim that serial execution
removed the whole class of subprocess-wait contention.

**Proposed fix.** Reproduce with per-test timing/last-started-test capture around the serial gate;
identify whether the Swift testing helper, an async teardown, or a subprocess test remains live.
Keep a bounded watchdog around CI test execution so a recurrence produces diagnostics rather than a
silent 40-minute timeout. Do not weaken or skip tests.

**Verification.** Repeated serial full-suite runs complete under a bounded timeout and a deliberately
wedged fixture produces the diagnostic/timeout path. Capture the last-started test when reproducing.

### F118 — Qwen cannot transcribe imported mp4/mov/aiff/caf recordings; failure message calls it transient

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** transcription
- **Filed:** 2026-07-31 by Claude Code (Fable 5, apple-design redesign session; user-reported failure)

**Problem.** The import feature accepts audio *and video* (`fileImporter(allowedContentTypes:
[.audio, .movie, .audiovisualContent])`, `Sources/WhisperMeet/ContentView.swift:333`) and copies the
file byte-for-byte with its original extension (`AppModel.copyImportedRecording`,
`AppModel.swift:811-817`). But the Qwen helper loads audio via mlx-audio's `load_audio`
(`Scripts/qwen_transcribe.py:126` → installed `mlx_audio/stt/utils.py:53` → `audio_io.py read()`),
which routes **only `.m4a`/`.aac` to ffmpeg** and everything else to **miniaudio**
(`…/site-packages/mlx_audio/audio_io.py:196-223`, pinned mlx-audio 0.3.1), which decodes only
wav/flac/mp3/ogg-vorbis. Any imported `.mp4`/`.mov`/`.aiff`/`.caf`/… therefore fails
deterministically at load with `miniaudio.DecodeError: unsupported file format` — reproduced
byte-for-byte against the installed runtime with synthetic fixtures (bench-clip conversions; user
recordings untouched). The same `.mp4` fixture transcribes cleanly through the installed Whisper
turbo (ffmpeg decode, `…/Runtime/venv/…/whisper/audio.py:43-46`). Corrupt/truncated WAVs produce a
*different* message ("could not open/decode file"), so this error signature specifically indicates
the format-dispatch case, not a damaged file. In-app recordings (16-bit PCM `meeting.wav`) are
unaffected.

**Impact.** A user who imports a video or mac-audio recording and selects (or defaults to) the
Qwen engine gets a guaranteed failure dressed as a transient one: the classifier fallback
(`Sources/WhisperCore/TranscriptionFailureClassifier.swift:49`) says "Transcription failed partway
through … try transcribing again", though it failed at 0% and retrying the same engine can never
succeed — plus a raw Python traceback. Nothing tells the user the file is fine and Whisper would
transcribe it.

**Decided direction (Simon, 2026-07-31 — this supersedes fixer's choice).** Accept more formats;
never surface a raw error for a format problem:
1. **Decode first.** When the selected engine cannot read the recording's container, transcode it
   locally (AVFoundation/`afconvert`) to 16 kHz mono WAV — at import time or as a temp file at
   transcription time — and feed the engine that. The original recording is never modified
   (recording-is-source-of-truth invariant); any temp clip is disposable.
2. **If decoding is impossible, guide — don't error.** No Python traceback and no dead-end alert:
   the failure surface must say the format isn't supported by the selected engine and offer
   switching to the other model (Whisper decodes everything via ffmpeg), e.g. an actionable
   message/control that re-runs with the other engine.
3. **Fix the classifier.** Map the `unsupported file format` stderr signature in
   `TranscriptionFailureClassifier` to that guidance — this failure is deterministic, so "try
   transcribing again" must go.
Verify any helper change against the pinned mlx-audio 0.3.1 source per AGENTS.md.

**Verification.** Red-green: a `TranscriptionFailureClassifier` test mapping the captured stderr to
the new guidance (fails before, passes after). Real-runtime: an `.mp4`/`.aiff` conversion of a
bench clip (e.g. `afconvert -f m4af … && cp x.m4a x.mp4`) transcribes successfully on the Qwen path
after the fix; a genuinely undecodable file produces the engine-switch guidance, not a traceback.

**Review note (2026-07-31, Codex /root).** Commit `0eb1a48` landed the classifier/guidance slice
without first setting this ticket `in-progress`, violating AGENTS.md ticket rule 4. The ticket stays
open because the required decode-first conversion and real Qwen imported-format run are still absent.

### F31 — Qwen meeting transcription reports no progress or ETA

- **Status:** blocked
- **Owner:** —
- **Severity:** medium
- **Area:** transcription
- **Filed:** 2026-07-30 by Claude Code (two-axis review, spec)
- **Blocked by:** F101 — the determinate bar needs the Qwen helper (`Scripts/qwen_transcribe.py`) to
  emit per-chunk progress. Verified 2026-07-31: the helper emits **zero** stdout/stderr during a real
  run, so there is nothing for `QwenASRClient` to stream-parse until the helper is changed.

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
progress today. The Swift-side streaming is ready to build the moment the helper emits
something; the helper change is the blocker.

**Verification.** A long Qwen run advances a determinate bar.

### F101 — Qwen helper must emit per-chunk progress so a meeting run can show a determinate bar

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** build
- **Filed:** 2026-07-31 by Claude Code (dependency for F31)

**Problem.** F31 needs a determinate progress bar for a long Qwen meeting, but the Qwen helper emits
no progress signal to parse. `Scripts/qwen_transcribe.py:129` calls `asr.generate(audio,
language=…, chunk_duration=240.0, min_chunk_duration=0.1)` with `verbose` defaulting to `False`.
In the pinned **mlx-audio 0.3.1** source, `Qwen3ASR.generate` chunks the audio and iterates
`tqdm(chunks, desc="Processing chunks", disable=not verbose or len(chunks) == 1)`
(`…/site-packages/mlx_audio/stt/models/qwen3_asr/qwen3_asr.py:1078,1108-1111`), so **no bar is
written unless `verbose=True` and there is more than one chunk**. A `stream=True` path also exists
that yields a `StreamingResult` per chunk (`qwen3_asr.py:1180,1244-1278`). Verified empirically on
2026-07-31: a real helper run over `Scripts/bench/clips/en2.wav` produced **zero** stdout/stderr.

**Why separate from F31.** The helper change (Python, under `Scripts/`) and the Swift consumer (F31:
streaming `QwenASRClient.run` + a Qwen progress parser mirroring `LocalWhisperClient.run` /
`WhisperProgressParser`) are two distinct changes with a natural order — the Swift half is ready to
build as soon as a stable progress format exists, but it must not guess the format before the helper
emits one.

**Proposed fix (coordinate the two halves).**
1. **Helper (`Scripts/qwen_transcribe.py`):** make the per-chunk progress observable on a stream the client reads.
   Lowest-risk is `verbose=True` so mlx-audio's own "Processing chunks" `tqdm` bar streams to stderr
   (matching the Whisper precedent of parsing `tqdm`); note it is suppressed for single-chunk
   (short) runs, which is acceptable since those finish quickly. A more explicit and single-chunk-safe
   alternative is to switch to `stream=True` and print one dedicated progress line per yielded chunk
   (e.g. a stable `QWEN_PROGRESS <done>/<total>` token on stderr). Re-verify the chosen call against
   the pinned mlx-audio 0.3.1 source per AGENTS.md and record the citation.
2. **`QwenASRClient` (`Sources/WhisperCore`):** replace `readDataToEndOfFile` with the streaming
   `AsyncStream<Data>` + `readabilityHandler` pattern already used by `LocalWhisperClient.run`, add a
   `QwenProgressParser` (unit-tested against captured helper output), and emit `.transcribing`
   `LocalTranscriptionProgress` with `fractionCompleted` (done/total) and an ETA.

**Verification.** With the helper change in place, a multi-chunk Qwen run advances a determinate bar
(fraction increases per completed chunk) and the label reads "Transcribing locally…"; a
`QwenProgressParser` unit test maps a captured progress line/`tqdm` frame to the expected fraction
(fails before, passes after).

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

- **Status:** in-progress
- **Owner:** Claude Code (Opus 4.8)
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

### F88 — Wire the "Second opinion" cross-engine comparison (delivers F73)

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** transcription
- **Filed:** 2026-07-31 by Claude Code (Opus 4.8)
- **Dependency (resolved):** F30 (Qwen timestamps) shipped 2026-07-31 (`fd56622`), so the
  Whisper→Qwen direction is no longer blocked and the full cross-engine comparison can be built.

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
- **Dependency (resolved):** F30 (Qwen timestamps) shipped 2026-07-31 (`fd56622`), so the Qwen
  menu item is no longer blocked; the Whisper path was already buildable.

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
