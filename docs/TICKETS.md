# Ticket board

**Single source of truth for outstanding work.** Every coding agent working on WhisperMeet — Claude
Code, Codex, or any other — MUST read this file before starting, file what it finds here, and record
what it resolves in [`TICKET_LOG.md`](TICKET_LOG.md).

This file holds **open** work only. Closed tickets move to the log; do not accumulate history here.

Related, and deliberately separate:
- [`ROADMAP.md`](ROADMAP.md) — prioritized *feature* backlog for improvement rounds. Aspirational.
- [`CHANGELOG.md`](CHANGELOG.md) — narrative record of shipped cycles, written for a human reader.
- [`TICKET_LOG.md`](TICKET_LOG.md) — append-only record of every ticket closed, with real evidence.

A roadmap item becomes a ticket when someone commits to doing it. A ticket is a concrete, verifiable
unit of work with an owner-independent definition of done.

## Rules for agents

1. **Read this file first.** If you are about to do work that is not on the board, file it as a
   ticket before you start, so parallel agents can see it.
2. **File what you find.** Any defect, regression, unverified claim, or follow-up you discover
   during other work gets a ticket — even if you are not going to fix it. Do not leave findings only
   in a chat reply; that context dies with the session.
3. **Claim before you work.** Set `Status: in-progress` and put your agent/session identifier in
   `Owner` in the same commit that starts the work. Never take a ticket already `in-progress`.
4. **Never delete a ticket.** Close it by moving the entry to `TICKET_LOG.md` with an outcome — that
   includes `wontfix` and `invalid`. Deleting loses the reasoning.
5. **One ticket, one commit trail.** Reference the ID in every commit message that touches it, in
   the existing repo style: `fix(dictation): keep helper stdout pure JSON (F24)`.
6. **Log on close.** Append to `TICKET_LOG.md` with real command output, not a summary of intent.
   The repo's culture is evidence over assertion — see the existing entries.

## ID allocation

IDs are `F<n>`, continuing the finding-ID series already used in commits and `CHANGELOG.md`.
**F1–F23 are consumed** by earlier review rounds (they predate this file and were never persisted —
their outcomes live in `CHANGELOG.md`).

**Next free ID: `F78`.** When you file a ticket, take the next ID and bump this line in the same
commit. If you hit a collision because another agent raced you, take the next free one and move on.

## Status vocabulary

| Status | Meaning |
|---|---|
| `open` | Filed, unclaimed, ready for anyone. |
| `in-progress` | Claimed. `Owner` is set. Do not touch. |
| `blocked` | Cannot proceed. `Blocked by:` states exactly what is needed and from whom. |
| `needs-human` | Requires a physical action or a decision only the user can make. |

Closed states (`fixed`, `wontfix`, `invalid`, `duplicate`) exist only in `TICKET_LOG.md`.

## Definition of done

A ticket may only be closed `fixed` when all of these hold:

- `swift build` and `swift test` both pass, and the test count did not silently drop.
- Behaviour changes are covered by a test that **fails before the fix and passes after**. State both
  results in the log. A fix with no failing-test-first evidence is not done.
- If the change touches the Whisper or Qwen subprocess contract, the live official docs were fetched
  and checked per [`../AGENTS.md`](../AGENTS.md) — flags and model names are never guessed.
- If the change touches a runtime helper or model adapter, it was exercised against the **real
  installed model**, not only a stub. Stubs cannot catch upstream API drift.
- The non-negotiable invariants in [`PRODUCT_SPEC.md`](PRODUCT_SPEC.md) are intact: local-only
  except opt-in Claude summaries, the recording is the source of truth, no diarization, original
  language only.
- No user meeting, recording, index, or transcript was read or modified for testing. Use
  `Scripts/bench/clips`.

## Ticket template

```markdown
### F<n> — <one-line summary>

- **Status:** open
- **Owner:** —
- **Severity:** high | medium | low
- **Area:** dictation | meetings | transcription | recovery | ui | build | docs
- **Filed:** YYYY-MM-DD by <agent/session>

**Problem.** What is wrong, and the evidence it is wrong. Cite `file.swift:line`.

**Impact.** Who or what breaks, and how it presents to the user.

**Proposed fix.** Optional. Say so if you are unsure.

**Verification.** How the fixer will prove it is done.
```

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

### F27 — Whisper vs Qwen dictation is unverified with a real microphone

- **Status:** needs-human
- **Owner:** —
- **Severity:** medium
- **Area:** dictation
- **Filed:** 2026-07-30 by Claude Code

**Problem.** The two engines have only been compared on the synthetic `Scripts/bench/clips` corpus,
fed to the helpers as files. Real push-to-talk adds microphone capture, room noise, accents,
variable clip length, and end-to-end release-to-text latency, none of which the file-fed comparison
exercises.

**Impact.** Any recommendation to prefer Qwen for dictation rests on clean synthetic audio and a
zero-error result that is almost certainly optimistic. The 0.36 s vs 1.43 s per-clip gap is the more
robust half of the finding, but it still excludes capture and delivery.

**Blocked by:** the user. Automated key injection is correctly rejected by the app's global hotkey
path, and microphone input cannot be synthesised — a person must hold the trigger and speak.

**Verification.** Same phrase through both engines with noise, accents, and mixed English/Mandarin.
Record release-to-text latency and any corrections needed. Append the numbers to `TICKET_LOG.md` and
correct the benchmark claims in `CHANGELOG.md` if they do not hold up.

### F28 — `WhisperCore` is no longer framework-free

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** build
- **Filed:** 2026-07-30 by Claude Code (two-axis review, standards)

**Problem.** `CLAUDE.md` states `WhisperCore` is "pure, `Sendable`, **framework-free** logic". Two
files now break that. 29 of 31 WhisperCore files import Foundation only; these are the exceptions:
- `Sources/WhisperCore/QwenASRClient.swift:2` — `import os`, and `:144` constructs
  `Logger(subsystem: "com.whispermeet.app", …)` inside the library. This also breaks *pure*: the
  alignment-failure warning becomes an OSLog side effect instead of being surfaced in
  `TranscriptionResult`, so neither callers nor tests can observe it. The app-identity string
  belongs in the `WhisperMeet` target.
- `Sources/WhisperCore/WarmWhisperDictationEngine.swift:2` — `import Darwin`, for `SIGKILL` at
  `:344`. Same rule, weaker case: there is no Foundation equivalent.

**Impact.** Erodes the split that makes `WhisperCore` unit-testable without a GUI. The
`QwenASRClient` case additionally hides a real diagnostic from tests, which is how the F24 class of
bug survives.

**Proposed fix.** Return the alignment warning through `TranscriptionResult` and let `WhisperMeet`
log it. For `SIGKILL`, either accept `import Darwin` with a documented exception in `CLAUDE.md`, or
move the force-stop into the app target.

**Verification.** `grep -rn "^import " Sources/WhisperCore/*.swift` shows Foundation only (plus any
exception `CLAUDE.md` explicitly sanctions); a test asserts the alignment warning is observable.

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

### F34 — `QUICK_DICTATION_DESIGN.md` still locks dictation to Whisper turbo

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** docs
- **Filed:** 2026-07-30 by Claude Code (two-axis review, spec)

**Problem.** `docs/QUICK_DICTATION_DESIGN.md:44` still records "Transcription engine | Local Whisper
`turbo`" and `:16` "shares only the local Whisper runtime", while
`DictationController.swift:109-116` now offers Qwen. The only authorization for the change is the
same cycle's own work log.

**Impact.** The design doc contradicts shipped behaviour, so it can no longer be trusted as the spec
for this feature — which is what the Spec review axis judges against.

**Verification.** The design doc describes the selector, its default, and the vocabulary limitation.

### F35 — `SelectableDictationEngine.replace` is a non-atomic read → await → write

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** dictation
- **Filed:** 2026-07-30 by Claude Code (two-axis review, standards)

**Problem.** `DictationProtocol.swift:83-95`. The `NSLock` makes each accessor safe, but `replace`
reads `current`, awaits `retire()`, then installs — so two concurrent replaces can both retire the
same engine. Safety today comes only from the `@MainActor` `isActive` / `isSwitchingModel` guard in
`DictationController.setSelectedEngine`, which lives in the *other* target.

**Impact.** No data race; a logical one. The class advertises `@unchecked Sendable`, implying it is
self-sufficient, but its correctness depends on a caller in another module.

**Proposed fix.** Serialize `replace` inside the class, or document the caller contract on the type.

**Verification.** Two concurrent `replace` calls leave exactly one live engine.

### F36 — The Qwen subprocess contract has no upstream documentation anchor

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** docs
- **Filed:** 2026-07-30 by Claude Code (two-axis review, standards)

**Problem.** `docs/TICKETS.md:61` requires live-doc verification "per `../AGENTS.md`" for the
Whisper **or Qwen** contract, but `AGENTS.md` names only whisperai.com and
github.com/openai/whisper. There is no Qwen / `mlx-audio` source listed, so the Qwen call contract
(`Scripts/qwen_transcribe.py:70-75`, `Scripts/qwen_dictate_server.py:24-29` —
`generate(language=, chunk_duration=, min_chunk_duration=)`) is unanchored.
`docs/ASR_EVALUATION_LOG_2026-07-29.md:9-13` claims docs "were checked" but cites no URL or version,
unlike the F24 entry which cites `mlx_whisper/transcribe.py:175`.

**Impact.** A rule that cannot be followed as written. Qwen API drift would not be caught.

**Proposed fix.** Add the pinned `mlx-audio` source to `AGENTS.md`, or require citing the installed
package source (as F24 did) when no upstream doc exists.

### F37 — Dictation is blocked while a *meeting* model runtime installs

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** dictation
- **Filed:** 2026-07-30 by Claude Code (two-axis review, spec)

**Problem.** `AppEntry.swift:14-17` folds `model.isInstallingRecognitionRuntime` into dictation's
`isMicrophoneBusy`. The spec only required the reverse (a meeting must not start while dictation
owns the mic).

**Impact.** Probably desirable — a multi-GB install contends for CPU and memory — but it is
undocumented, and it is not a microphone conflict, so expressing it as "microphone busy" makes the
reason opaque to the user and to future readers.

**Verification.** Confirm the behaviour is intended, then document it and give it an accurate
user-facing reason.

## Defects — filed 2026-07-30 from the codebase-wide fix sweep

Each entry below was confirmed by an adversarial verifier that re-read the cited code and traced the
failing path; the `file:line` references were checked against the working tree. Ordered worst-first:
F38–F41 medium, F42–F54 low.

### F38 — Toggle-mode dictation hotkey desyncs when a press-start is refused

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** dictation
- **Filed:** 2026-07-30 by Claude Code (fix sweep, verified)

**Problem.** In toggle mode `HotkeyMonitor.dispatch` flips `toggledOn` on every down edge and picks
start-vs-end from the result (`Sources/WhisperMeet/Dictation/HotkeyMonitor.swift:131`).
`DictationController.handlePressStart` can refuse the start without telling the monitor: it
early-returns on `!enabled || isSwitchingModel`, on `isMicrophoneBusy()` (only `flashBusy()`), and
when `session.handle(.startPressed)` returns `.busy`
(`Sources/WhisperMeet/Dictation/DictationController.swift:256-270`). After a refusal the monitor
still believes dictation is "on", so the next press fires `onPressEnd`, which no-ops because
`recorder.isRecording` is false.

**Impact.** A toggle-mode user who tries to dictate while a meeting is recording, while the model is
switching, or while a prior dictation is still transcribing gets a silent no-op and an inverted
on/off state — the next one or two presses do nothing (and the even presses show no busy flash)
before capture actually starts. Toggle is a first-class Settings mode (`ContentView.swift:1120`).

**Proposed fix.** Let the controller drive the monitor's toggle state (reset `toggledOn` when a
start is refused), or move the on/off truth into `DictationController`/`DictationSession` and have
the monitor report only raw edges.

**Verification.** Controller-level test: put the session in busy/switching/mic-busy state, deliver a
toggle down edge, and assert the NEXT down edge still starts capture. Fails before, passes after.

### F39 — Changing the dictation trigger key leaves `hotkeyActive`/`status` stale

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** dictation
- **Filed:** 2026-07-30 by Claude Code (fix sweep, verified)

**Problem.** The `hotkey` didSet restarts the monitor with `_ = hotkeyMonitor.start(hotkey:)` and
discards the `Bool` (`Sources/WhisperMeet/Dictation/DictationController.swift:31`). Unlike `apply()`
(`:182-189`) it never updates `hotkeyActive` or `status`. So after enabling dictation without
Accessibility (status `.error`, `hotkeyActive=false`), granting Accessibility, then changing the
key, the tap is re-created successfully but `status` stays `.error` and `hotkeyActive` stays false;
the reverse — a re-tap that now fails — is silent.

**Impact.** The "Hotkey listening" diagnostics row (`DictationView.swift:30`) stays red and the
menu-bar icon stays on the error glyph (`AppEntry.swift:37-43`) even though dictation is working —
or vice versa. The only resync is toggling dictation off/on. Realistic sequence: enable → error →
grant permission → adjust key.

**Proposed fix.** Route the didSet through the same success/failure handling `apply()` uses instead
of discarding the `start()` result.

**Verification.** Inject a `HotkeyMonitor` whose `start()` result is controllable; set `status` to
`.error`, assign a new hotkey with `start()` succeeding, and assert `hotkeyActive == true` and
`status == .idle`. Fails before, passes after.

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

### F41 — Qwen auto-detect labels any transcript containing a single CJK character as `zh`

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** transcription
- **Filed:** 2026-07-30 by Claude Code (fix sweep, verified)

**Problem.** Under `--language auto` (the default; `Sources/WhisperCore/QwenASRClient.swift:126`
passes `language.commandLineValue ?? "auto"`), the reported language code is a whole-text CJK-any
heuristic: `language_code = "zh" if alignment_language(text, "auto") == "Chinese" else "en"`
(`Scripts/qwen_transcribe.py:111`), where `alignment_language` returns "Chinese" if
`any("㐀" <= char <= "鿿" for char in text)` (`:25-27`). So a mostly-English meeting mentioning one
Chinese name or term (e.g. "meet in 北京") is labeled `zh`. There is no majority/threshold, and it
ignores what the ASR actually detected. Whisper on the same audio reports `en`.

**Impact.** Systematic mislabel of the core "detect English or Mandarin" feature on the default
path. The wrong code shows in the header chip (`ContentView.swift:1496`) and is injected into the
Claude summary system prompt ("detected language code is \"zh\"", `ClaudeSummarizer.swift:89-90`),
which can bias summary output language. Cross-engine inconsistency with Whisper on the same file.

**Proposed fix.** Report the language the ASR actually detected, or use a proportion threshold
(label `zh` only when CJK is the majority of non-whitespace characters). The per-chunk aligner
language can stay as-is; only the top-level `language_code` needs the fix.

**Verification.** A test that maps a mostly-English string containing one CJK character to `en` (a
threshold rule), not `zh`. Fails before, passes after.

### F42 — Export strips a leading clock-like token as a timestamp on non-timestamped transcripts

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** transcription
- **Filed:** 2026-07-30 by Claude Code (fix sweep, verified)

**Problem.** Both export paths consume a leading `\d{1,3}:\d{2}` token as a cue timestamp without
checking the transcript is actually timestamped. `transcriptLines`
(`Sources/WhisperCore/TranscriptExporter.swift:149-173`) does it for SRT/VTT/JSON;
`TranscriptFormatter.stripTimestamps` (`TranscriptModels.swift:252-263`) for plain text. A
non-timestamped transcript — e.g. the Qwen path stores `result.text` verbatim
(`AppModel.swift:965-966`) — with a line like "3:00 PM kickoff" loses "3:00" (plain text → "PM
kickoff"; SRT/VTT emit a cue at 00:03:00 with text "PM kickoff").
`TranscriptFormatter.isTimestamped` exists (`:223`) but is never applied in the export path.

**Impact.** A user exporting a Qwen (untimestamped) transcript silently loses the leading clock-like
token of any line beginning with one, and cues are mis-timed. The stored transcript is unchanged
(re-exportable), so this is a wrong export file rather than permanent loss, but it is silent.

**Proposed fix.** Gate stripping/parsing on `TranscriptFormatter.isTimestamped` (or on real segments
existing); be conservative — do not strip unless the transcript is genuinely timestamped.

**Verification.** `render(.plainText, …)` with `transcriptText: "3:00 PM kickoff", segments: []`
must equal "3:00 PM kickoff" (returns "PM kickoff" today); an SRT case asserts the cue text still
contains "3:00". Fails before, passes after.

### F43 — In-transcript find double-counts overlapping/duplicate query terms

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** ui
- **Filed:** 2026-07-30 by Claude Code (fix sweep, verified)

**Problem.** `occurrenceRanges` (`Sources/WhisperCore/TextSearch.swift:41-63`) iterates each
whitespace-split term independently and concatenates hits; `occurrences` (`:68-78`) counts them. Two
terms covering the same text — a duplicate word ("the the") or a substring pair ("meet meeting") —
count the same visible region twice. ContentView drives the "X of N" label, Prev/Next, and
highlighting from these (`ContentView.swift:2062,2071-2076,2365`); overlapping highlight ranges also
clobber each other (the later `backgroundColor` write wins).

**Impact.** Inflated match count, Prev/Next stepping onto visually identical positions, and a
selected-match highlight that can be overwritten. Uncommon trigger (duplicate-word typo, or a term
that is a prefix of another).

**Proposed fix.** Merge/deduplicate overlapping ranges before counting and navigating, and keep
highlighting consistent with the deduped list.

**Verification.** `occurrenceRanges("meet meeting", in: "the meeting is set").count == 1` (returns 2
today); `occurrences("the the", in: ["the cat"]).count == 1`. Fails before, passes after.

### F44 — WebVTT/SubRip export writes cue text unescaped

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** transcription
- **Filed:** 2026-07-30 by Claude Code (fix sweep, verified)

**Problem.** `vtt` appends the raw segment text (`Sources/WhisperCore/TranscriptExporter.swift:216`)
and `srt` embeds it raw (`:202`) with no escaping. WebVTT requires `&`→`&amp;`, `<`→`&lt;`, and
forbids the literal `-->` in cue payload. An edited transcript containing "R&D", "5 < 10", or a
stray "-->" therefore emits spec-invalid WebVTT.

**Impact.** Subtitle files that strict players/validators reject or mis-render. Everyday CJK/English
speech rarely contains these characters; it bites edited transcripts ("AT&T", "C < D").

**Proposed fix.** Escape `&`, `<`, `>` in cue text and neutralize any `-->` inside a cue; escape
`<`/`>` in SRT too to avoid accidental tag interpretation.

**Verification.** A segment text "R&D <plan> --> done" → VTT output contains "R&amp;D &lt;plan&gt;"
and no literal "-->" inside the cue. Fails before, passes after.

### F45 — ClaudeSummarizer never handles `stop_reason == "max_tokens"`

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** meetings
- **Filed:** 2026-07-30 by Claude Code (fix sweep, verified)

**Problem.** The request caps output at `maxTokens = 4_000`
(`Sources/WhisperCore/ClaudeSummarizer.swift:18`, sent at `:63`). `decodeSummary` (`:119-140`)
branches only on `stop_reason == "refusal"` (`:123`). On a token-cap hit the API returns HTTP 200
with `stop_reason == "max_tokens"` and truncated JSON; the code extracts it and
`JSONDecoder().decode(MeetingSummary.self, …)` fails, throwing `.unreadableResponse` → "Claude
returned a summary the app could not read." (`MeetingSummarizer.swift:41`). No branch distinguishes
truncation from genuinely garbled output.

**Impact.** A long meeting whose summary + key points + action items exceed ~4000 output tokens
fails with a misleading, non-actionable error; retrying will not help without raising the cap. The
recording/transcript are untouched.

**Proposed fix.** Detect `stop_reason == "max_tokens"` and throw a dedicated `.responseTruncated`
with guidance; and/or raise the `maxTokens` default well above 4_000.

**Verification.** A `URLProtocol` stub returns 200 with `"stop_reason":"max_tokens"` and truncated
JSON; assert the current `.unreadableResponse` (documents the bug), then after the fix a distinct
actionable error. Fails before, passes after.

### F46 — Preflight headline contradicts its own microphone note on transient-only capture

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** ui
- **Filed:** 2026-07-30 by Claude Code (fix sweep, verified)

**Problem.** `isReady`/`isCapturing` derive from `isSustained`
(`Sources/WhisperCore/PreflightTest.swift:135,144`). A lone transient (peak ≥ silentCeiling but
crest factor > 20) is not sustained, so `isCapturing` is false and the headline hits "No microphone
audio was captured — fix this before your meeting." (`:146-147`), while `micNote` via
`isTransientOnly` (`:160-167`) simultaneously returns "Only a brief sound (a click or tap) was
detected…". The headline and its own note contradict each other.

**Impact.** A user who tapped the mic or had a cable pop sees a top-line verdict claiming no mic
audio at all, contradicting the accompanying note, and may debug a non-problem. The readiness
decision itself is correct (a click is not speech).

**Proposed fix.** Add a transient-specific headline branch (reusing `isTransientOnly`) before the
generic "no audio" branch so the headline and note agree.

**Verification.** A `PreflightAssessment` with a lone-transient microphone signal and a silent
system signal → `isReady == false` and the headline does not claim "No microphone audio was
captured" while the note mentions a brief/transient sound. Fails before, passes after.

### F47 — Startup orphan-recovery aborts all remaining orphans on the first throwing folder

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** recovery
- **Filed:** 2026-07-30 by Claude Code (fix sweep, verified)

**Problem.** `performStartupRecovery` wraps the whole `for orphan in try store.orphanedRecordings()`
loop in one do/catch (`Sources/WhisperMeet/AppModel.swift:240-306`).
`InterruptedRecordingRecovery.recover()` performs throwing I/O
(`InterruptedRecordingRecovery.swift:77-116`), so a throw on orphan N propagates to the single catch
(`:302`), skipping orphans N+1…. Orphans iterate in a stable `createdAt` order
(`MeetingStore.swift:196`), so a persistently-failing folder blocks every later orphan on every
launch.

**Impact.** Non-destructive (raw tracks are never deleted, so audio is safe), but recovered
recordings after a failing folder never reappear in the library and the user sees only a generic
"could not finish scanning" message.

**Proposed fix.** Wrap each orphan iteration in its own do/catch so one failure appends a per-folder
message and continues to the next orphan.

**Verification.** Three orphan folders where the middle one makes `recover()` throw; assert the
first and third are both upserted into the store. Fails before, passes after.

### F48 — `AudioCaptureEngine.stop()` can throw before its `reset()` defer, wedging the engine

- **Status:** in-progress
- **Owner:** Codex / root
- **Severity:** low
- **Area:** meetings
- **Filed:** 2026-07-30 by Claude Code (fix sweep, verified)

**Problem.** In `stop()`, `try systemWriter?.finish()` / `try microphoneWriter?.finish()`
(`Sources/WhisperMeet/AudioCaptureEngine.swift:188-189`) can throw because `finish()` calls
`handle.close()` (`:554`), but `defer { reset() }` is only registered at `:193` — after. A throw
exits `stop()` without `reset()`, leaving `self.stream` non-nil. The next `start()` hits
`guard stream == nil else { return }` (`:71`) and returns early with no throw and without installing
the health/level callbacks; `AppModel.startRecording` sees no error and sets
`recordingState = .recording` over a dead engine (`AppModel.swift:440`).

**Impact.** After a `stop()` that throws from `finish()` (rare — e.g. a full or failing volume),
every subsequent "recording" is a silent no-op until relaunch, breaking "every failure is
retryable". The recording being stopped is still recoverable from its raw `.f32` tracks on next
launch; the loss falls on all later recordings.

**Proposed fix.** Register `defer { reset() }` immediately after the initial
`guard let stream, let directory`; on the `finish()` throw path also call `preservePartialTracks()`.

**Verification.** With an injectable writer that throws from `finish()`, assert that after `stop()`
throws the engine has `stream == nil` so a following `start()` proceeds and installs callbacks.
Fails before, passes after.

### F49 — Vocabulary import is UTF-8-only; one bad file aborts the whole batch

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** transcription
- **Filed:** 2026-07-30 by Claude Code (fix sweep, verified)

**Problem.** `VocabularyExtractor.extract` decodes txt/md/markdown/csv with
`String(contentsOf:encoding:.utf8)` (`Sources/WhisperMeet/VocabularyExtractor.swift:33`), which
throws on any non-UTF-8 file (Excel CSV as Windows-1252, UTF-16, Latin-1 `.txt`). The batch importer
runs `try urls.flatMap(VocabularyExtractor.extract(from:))` (`ContentView.swift:1359`) inside one
do/catch, so one throwing file aborts extraction for the entire batch and imports zero terms.
CLAUDE.md lists CSV as a supported import format.

**Impact.** Importing a glossary set where any one file is non-UTF-8 shows "The selected document
could not be read" and imports nothing. No data loss, but a common real-world file silently blocks
the feature.

**Proposed fix.** Use `String(contentsOf:usedEncoding:)` or try a small list of fallback encodings
(utf8, utf16, isoLatin1/windowsCP1252); have the importer collect per-file failures instead of
aborting the whole `flatMap`.

**Verification.** A UTF-16 (or Windows-1252) `.csv` fixture returns candidate terms instead of
throwing; a batch with one bad file still returns the good files' terms. Fails before, passes after.

### F50 — Hold-mode dictation has no capture cap or stuck-listen watchdog

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** dictation
- **Filed:** 2026-07-30 by Claude Code (fix sweep, verified)

**Problem.** `MicDictationRecorder` appends every chunk to `samples` with no size/duration cap
(`Sources/WhisperMeet/Dictation/MicDictationRecorder.swift:102-103`), and `DictationController` has
no timeout on `.listening` — capture ends only on a matching `handlePressEnd`. `HotkeyMonitor`
re-enables the tap on `.tapDisabledByTimeout`/`.tapDisabledByUserInput`
(`HotkeyMonitor.swift:42-45`) but events during the disabled window are dropped; the modifier path
self-heals from absolute state (`:92`) but the keyDown/keyUp path used for F-keys does not, so a
missed key-up leaves `keyDown = true` and the recorder hot.

**Impact.** Rare but real: after an OS tap-disable during a hold (or an F-key hotkey whose up edge
is dropped), dictation is wedged in `.listening`, the mic stays hot, the overlay stays up, and the
buffer grows (~64 KB/s at 16 kHz Float32) until the user disables dictation. F-keys are an
explicitly recommended trigger (`ContentView.swift:1130`).

**Proposed fix.** Cap capture duration (and buffer size) with a watchdog that finalizes or cancels;
on tap re-enable, resynchronize `keyDown` from the current hardware key state.

**Verification.** Simulate a missed key-up (a `handlePressStart` with no matching `handlePressEnd`)
and assert the session self-recovers to idle and the recorder stops after a max duration. Fails
before, passes after.

### F51 — Qwen segment parsing is unguarded; a schema drift discards the whole transcript

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** transcription
- **Filed:** 2026-07-30 by Claude Code (fix sweep, verified)

**Problem.** The full transcript `text` is produced at `Scripts/qwen_transcribe.py:79`.
`align_chunks` is deliberately try/except-wrapped so an alignment failure still preserves the text
(returns `[], warning`), but the ASR segment extraction at `:82-90`
(`for segment in transcription.segments`, indexing `segment["text"/"start"/"end"]`) runs before
alignment with no guard. If mlx_audio's segment schema changes, a `KeyError`/`AttributeError`
propagates out of `main()`, the process exits non-zero (the payload with `text` is only written at
`:113-124`), and `QwenASRClient.run` raises `.processFailed`
(`Sources/WhisperCore/QwenASRClient.swift:196-201`) — so the user gets no transcript even though the
complete text existed. This is distinct from F30 (timestamps dropped all-or-nothing); here the TEXT
is lost.

**Impact.** A meeting where Qwen produced a correct full transcript becomes a hard failure instead
of the documented "complete text remains authoritative" degradation. Latent — the pinned mlx-audio
0.3.1 keys currently work; it only manifests on a dependency schema change.

**Proposed fix.** Wrap the segment-building block so any failure degrades to `chunks=[]` plus an
`alignmentWarning` and still writes the payload with the full `text`, mirroring how `align_chunks`
already preserves text.

**Verification.** A Python test with a fake model whose `.generate` returns a valid `.text` but
unexpected `.segments`: the script exits non-zero today; after the fix it exits 0 with the full
`text`, `alignedItems: []`, and a non-null `alignmentWarning`. Fails before, passes after.

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

### F53 — Qwen empty/silent clip surfaces a raw Python traceback

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** transcription
- **Filed:** 2026-07-30 by Claude Code (fix sweep, verified)

**Problem.** On empty text the Qwen helper does
`raise RuntimeError("Qwen3-ASR returned an empty transcript.")` (`Scripts/qwen_transcribe.py:80-81`)
BEFORE writing any output JSON, so the process exits non-zero. `QwenASRClient.run` hits the
`terminationStatus == 0` guard first and throws `.processFailed` with the captured stdout/stderr —
the traceback (`Sources/WhisperCore/QwenASRClient.swift:196-201`). The dedicated `.emptyTranscript`
("No speech was detected…") guard (`:141-142`) can never fire. The Whisper path handles the same
case cleanly (`LocalWhisperClient.swift:170-171`).

**Impact.** Transcribing a silent/very-short/non-speech clip with Qwen shows a modal alert
containing a raw Python traceback instead of the designed "No speech was detected", violating the
plain-language spec requirement and leaving `.emptyTranscript` dead code — an engine-to-engine
inconsistency for the same audio.

**Proposed fix.** Have the helper write an empty-text payload and `return 0` so the client's
existing `.emptyTranscript` guard runs; or special-case the sentinel string in the client.

**Verification.** A stub helper that exits 0 with `{"text":"",…}` → `client.transcribe` throws
`.emptyTranscript`, not `.processFailed`. Fails before, passes after.

### F54 — CHANGELOG intro test-count claim is stale

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** docs
- **Filed:** 2026-07-30 by Claude Code (fix sweep, verified)

**Problem.** The CHANGELOG opening summary says "Test count grew 28 → 157." (`docs/CHANGELOG.md:6`),
but its own later cycle entries record higher totals — 169/169 (`:103`), 176/176 (`:66`), and the
most recent 178/178 (`:29`). The header contradicts the file's own evidence and understates the
suite.

**Impact.** The next agent reading the top-of-file summary is told the suite is 157 tests when the
latest recorded run is 178, undermining the CHANGELOG's role as evidence.

**Proposed fix.** Update line 6 to the current suite size (the latest cycle logs 178), or reword so
it does not pin a specific stale number.

**Verification.** Run `swift test`, count the executed tests, and update line 6 to match the newest
recorded per-cycle count.

## Feature tickets — filed 2026-07-30 from the multi-lens feature discovery

New functionality, ranked best-first by value / effort with identity fit and risk weighed in. Each
is grounded in a named type/file that was confirmed to exist and carries a WhisperCore-testable core
with a fails-before/passes-after definition of done. These respect the non-negotiable invariants
(local-only except the opt-in Claude summary, recording is source-of-truth, no diarization, original
language). Tickets that concretize an existing `ROADMAP.md` "Next candidate" note it explicitly.

### F55 — Engine-agnostic repetition flag: text-derived quality review for Qwen/legacy transcripts

- **Status:** open
- **Owner:** —
- **Severity:** — (feature; impact M / effort L / risk L)
- **Area:** transcription
- **Filed:** 2026-07-30 by Claude Code (feature discovery)

**Problem.** `TranscriptQuality` only scores segments carrying Whisper's
`avgLogprob`/`noSpeechProb`/`compressionRatio`. `QwenAlignedTranscript.segments`
(`Sources/WhisperCore/QwenAlignedTranscript.swift:43-48`) builds every segment with all three nil,
so `classify()` (`TranscriptQuality.swift:115-120`) returns nil, `isUnscored` is true, and the
quality banner (`ContentView.swift:2149`) never appears for any Qwen meeting — including Qwen's most
common failure, a degenerate loop.

**Proposed feature.** Add a pure, framework-free repetition heuristic to WhisperCore (deterministic
n-gram / longest-repeat over `TranscriptSegment.text`, not Foundation's compression API) yielding a
compression-ratio equivalent from text alone. Extend `TranscriptQuality.classify` so
`SegmentQualityFlag.repetitive` is reachable when `compressionRatio == nil`, while keeping
`.lowConfidence`/`.likelySilence` gated on real model metrics. Count a text-only-scored segment
toward `scoredCount` so `isUnscored` flips to false.

**Invariants.** Read-only classification; audio untouched; no translation; speaker stays nil; stays
framework-free (pure-Swift text math).

**Verification.** In `TranscriptQualityTests`: a Qwen-style `[TranscriptSegment]` with all metrics
nil but text "yes yes yes yes yes yes yes" yields a `.repetitive` flag and
`report.isUnscored == false`; a clean nil-metric segment stays unflagged and
`.lowConfidence`/`.likelySilence` never fire without real metrics. Fails before, passes after.

### F56 — Persist an overall transcript confidence into the header and Meeting Notes

- **Status:** open
- **Owner:** —
- **Severity:** — (feature; impact M / effort L / risk L)
- **Area:** transcription
- **Filed:** 2026-07-30 by Claude Code (feature discovery)

**Problem.** The only trust figure is ephemeral ("X% clean", `ContentView.swift:2287`), recomputed
in the detail banner and present in no export. `MeetingRecord.confidence` (`MeetingStore.swift:40`)
is dead: rendered in the header (`ContentView.swift:1499-1500`) but `AppModel` forces it nil
(`AppModel.swift:969`) and both clients return `confidence: nil` (`LocalWhisperClient.swift:190`,
`QwenASRClient.swift:155`). Depends on F55 to be meaningful on Qwen.

**Proposed feature.** In `AppModel.apply(result:to:)` (`:962-976`) set
`$0.confidence = TranscriptQuality.review(result.segments).confidence`, reviving the header label.
Add a confidence section to `MeetingNotesExporter.markdown` (`MeetingNotesExporter.swift:7`): a "NN%
clean — K of M segments flagged" headline plus a worst-first list from `report.flaggedBySeverity`
with each flagged passage's MM:SS and `SegmentQualityFlag.reason`. Gate the whole section on
`!report.isUnscored && !TranscriptFormatter.isEdited` so an unscored or edited transcript makes no
false claim.

**Invariants.** Read-only over segments; audio untouched; unscored/edited transcripts make no
confidence claim (never fabricates trust); no diarization/translation.

**Verification.** In `MeetingNotesExporterTests`: segments with a known flagged fraction emit the
"NN% clean / K flagged" line and worst-first MM:SS entries; an unscored or edited transcript emits
no confidence section. Fails before, passes after.

### F57 — Local notification when a meeting transcription finishes or fails

- **Status:** open
- **Owner:** —
- **Severity:** — (feature; impact M / effort L / risk L)
- **Area:** ui
- **Filed:** 2026-07-30 by Claude Code (feature discovery)

**Problem.** A long Whisper Large run reports nothing on completion; the user must watch the
progress bar. Dictation already notifies (`DictationController.notifyClipboard`,
`DictationController.swift:451-457`) but `AppModel.apply(result:to:)` (`:962`) and
`handle(error:id:)` (`:986`) post nothing.

**Proposed feature.** Add a pure `TranscriptionNotification` to WhisperCore:
`content(title:outcome:segmentCount:) -> (title, body)` for completed/failed (cancelled → none) and
`shouldNotify(outcome:appIsActive:)` suppressing while frontmost. Wire into
`AppModel.apply(result:)`/`handle(error:)` reusing the dictation `UNUserNotificationCenter` pattern;
tapping activates the app and selects that meeting.

**Invariants.** Local OS notification only — nothing uploaded, does not touch the Claude path; body
carries only title + outcome, never transcript content; recording/transcript unchanged.

**Verification.** New `TranscriptionNotificationTests`: completed → title "Transcript ready", body
contains only the meeting title; failed → failure phrasing; cancelled → nil; `shouldNotify` false
when active, true when backgrounded. Fails before, passes after.

### F58 — Post-meeting recording-health report: persist why a recording was bad

- **Status:** open
- **Owner:** —
- **Severity:** — (feature; impact H / effort M / risk L)
- **Area:** meetings
- **Filed:** 2026-07-30 by Claude Code (feature discovery)

**Problem.** A meeting where system audio was never detected, or the mic went stale mid-recording,
becomes a `MeetingRecord` with no trace: the live `RecordingHealthSnapshot.warnings`
(`RecordingHealthMonitor.swift:62-72,121-155`, surfaced via `AppModel.recordingHealth`) are thrown
away on stop, so the user may blame the model for a capture failure.

**Proposed feature.** Add a pure `RecordingHealthReport` value plus
`RecordingHealthMonitor.report()` folding across the capture: the distinct warnings seen, the worst
status reached, per-channel total stale seconds, and whether system audio was ever detected. Persist
as optional `MeetingRecord.healthReport` (`MeetingStore.swift:31`, exactly like the existing
optional markers/`transcriptNormalized` so old indexes decode). Render a one-line advisory in the
detail reusing the Round-9 banner pattern.

**Invariants.** Advisory only, derived from level data already computed during capture; audio
untouched; channel-level (mic vs system track), not speaker identity; local-only.

**Verification.** New `RecordingHealthReportTests`: a scripted `receive()`/`snapshot()` sequence
where system audio never arrives and the mic goes stale → the report lists
`.systemAudioNotDetected`, worst status `.atRisk`, and the correct mic stale-seconds total; a
`MeetingRecord` JSON without `healthReport` still decodes. Fails before, passes after.

### F59 — Faceted meeting search: filter by language, status, duration, and date

- **Status:** open
- **Owner:** —
- **Severity:** — (feature; impact H / effort M / risk L)
- **Area:** meetings
- **Filed:** 2026-07-30 by Claude Code (feature discovery)

**Problem.** `filteredMeetings` (`ContentView.swift:36-42`) only substring-matches title+transcript
via `TextSearch.matches` (`TextSearch.swift:17`). A user cannot ask for "Mandarin meetings over 30
minutes from June" even though `languageCode`/`status`/`duration`/`createdAt` all already live on
`MeetingRecord` (`MeetingStore.swift:31-42`).

**Proposed feature.** New pure `MeetingQuery` in WhisperCore: `parse(_:)` peels tokens
(`lang:en|zh`, `status:…`, `before:/after:YYYY-MM-DD`, `min:/max:` durations) and leaves the
remainder as free text; `matches(_ facets:)` where a small `Facets` value carries the fields. Free
text delegates to `TextSearch.matches` so shipped search is byte-identical with no token. Wire by
replacing the body of `filteredMeetings` and updating the `.searchable` prompt (`:82`).

**Invariants.** Read-only over fields already in the index; no audio/network; language is a filter
facet only, never changing `--task transcribe`; no diarization.

**Verification.** New `MeetingQueryTests`: `lang:zh` excludes an English facet; `min:30m` excludes a
10-minute meeting; `before:2026-06-01` excludes a July facet; a bare word matches identically to a
direct `TextSearch.matches` call (explicit regression guard). Fails before, passes after.

### F60 — Chapters export: turn recording markers into a chapter list + chaptered transcript

- **Status:** open
- **Owner:** —
- **Severity:** — (feature; impact H / effort M / risk L)
- **Area:** export
- **Filed:** 2026-07-30 by Claude Code (feature discovery)

**Problem.** Markers only produce a flat "## Markers" list (`RecordingMarkers.markdownSection`,
`Sources/WhisperCore/RecordingMarker.swift:77`). There is no navigable chapter structure and no
standard chapter-file artifact.

**Proposed feature.** New pure `TranscriptChapters`: given `[RecordingMarker]`,
`[TranscriptSegment]`, and `durationSeconds`, partition the timeline into chapters bounded by marker
offsets (leading chapter from 0; no markers → one chapter) and produce (a) a "MM:SS Title"
one-line-per-chapter list using `RecordingMarkers.displayLabel` and `TranscriptFormatter.timestamp`,
and (b) a chaptered Markdown transcript grouping each segment under a "## MM:SS Title" heading. Add
`chapterList`/`chapteredMarkdown` cases to `TranscriptExportFormat` (`TranscriptExporter.swift:6`).
Grounding fix: add a defaulted `markers: [RecordingMarker] = []` to `TranscriptExportRequest.init`
(`:53`) and pass `current.orderedMarkers` from `exportTranscript` (`ContentView.swift:1779-1787`).

**Invariants.** Timestamps only — chapters are time ranges, never speakers; fully local;
original-language text copied verbatim; WAV never read/modified.

**Verification.** New `TranscriptChaptersTests`: markers at 0:00/5:00/12:30 over 20:00 yield exactly
3 chapters with correct [start,end) ranges; each segment assigned by its start; a boundary-start
segment goes to the later chapter; an unlabeled marker renders "Marker N"; empty markers yield one
full-duration chapter. Fails before, passes after.

### F61 — Self-contained printable HTML transcript export

- **Status:** open
- **Owner:** —
- **Severity:** — (feature; impact H / effort M / risk L)
- **Area:** export
- **Filed:** 2026-07-30 by Claude Code (feature discovery)

**Problem.** The only single-file human-readable export is Markdown (`TranscriptExporter.markdown`,
`Sources/WhisperCore/TranscriptExporter.swift:175`), which non-technical recipients cannot render
and which has no clean Print-to-PDF path.

**Proposed feature.** Add a `html` case to `TranscriptExportFormat` (`:6`) and an `html(_ request:)`
renderer emitting a standalone document: an inline `<style>` block (no external CSS/fonts/images),
HTML-escaped transcript text, per-segment MM:SS anchors, and an optional markers table-of-contents +
summary header when present (reuse the defaulted fields from F60). Wires in free via the `allCases`
Export menu (`ContentView.swift:1673`) and `saveExport` (`:1810`).

**Invariants.** Fully local — the no-external-URL assertion structurally enforces it; original
language preserved verbatim (only HTML-escaped); no diarization; recording untouched.

**Verification.** In `TranscriptExporterTests`: a request whose text contains `<`, `&`, `"` escapes
them; exactly one `<html` and one `<style>`; NO `http://`/`https://` anywhere (offline guarantee);
every segment timestamp appears; an empty transcript still yields a valid minimal document. Fails
before, passes after.

### F62 — Menu-bar recording controls with live status

- **Status:** open
- **Owner:** —
- **Severity:** — (feature; impact H / effort M / risk M)
- **Area:** ui
- **Filed:** 2026-07-30 by Claude Code (feature discovery)

**Problem.** During a real meeting the record controls live only in `ContentView` and need the
window frontmost; the `MenuBarExtra`'s `DictationMenu` (`AppEntry.swift:47-59`) today only toggles
dictation/Settings/Quit — no elapsed time, Stop, Add Marker, or Cancel. Concretizes ROADMAP Next
candidate #2.

**Proposed feature.** Core: a pure a pure `MenuBarRecordingPresentation.make(...)` taking
`isRecording`, `isStopping`, `elapsedSeconds`, `isMicrophoneBusy`, and `hasActiveTranscription`
returning menu titles, per-item enabled flags, an SF Symbol, and a `cancelNeedsConfirmation` flag.
Extend the `MenuBarExtra` so the symbol and menu reflect `AppModel.recordingState` and add Start,
Stop & Transcribe, Add Marker (`AppModel.addLiveMarker()`, `:532`), and a guarded Cancel Recording…
that activates the app and triggers the existing `isConfirmingCancellation` dialog (never deletes
inline).

**Invariants.** Recording stays source-of-truth: Stop uses `AppModel.stopRecording` (no mutation on
failure); Cancel is the only destructive path and stays behind the existing confirmation;
local-only; no diarization/translation.

**Verification.** New `MenuBarRecordingPresentationTests`: idle → "Start Recording" enabled, stop/
marker disabled; recording(323s) → title "Recording 05:23", Stop & Add Marker enabled,
`cancelNeedsConfirmation` true; stopping/importing → actions disabled. Fails before, passes after.
Menu wiring verified manually (no `WhisperMeet` test target); state so in the log.

### F63 — Summary style controls for the opt-in Claude summary

- **Status:** open
- **Owner:** —
- **Severity:** — (feature; impact M / effort L / risk L)
- **Area:** export
- **Filed:** 2026-07-30 by Claude Code (feature discovery)

**Problem.** `ClaudeSummarizer.summarize` uses one fixed system prompt
(`Sources/WhisperCore/ClaudeSummarizer.swift:79`) producing one shape/length; the only recourse is
re-running the identical prompt.

**Proposed feature.** Add `public enum SummaryStyle` (`.balanced` default, `.brief`, `.detailed`,
`.actionItemsFocused`) in `MeetingSummarizer.swift`; thread it through the protocol as
`summarize(transcript:language:style:)` (defaulted for source compatibility) and into
`ClaudeSummarizer.systemPrompt(language:style:)` appending style-specific guidance while leaving the
schema and the "do not translate / write in the transcript's language" clause unchanged. Add a
compact style picker + Regenerate next to the summary UI (`ContentView.swift:~1427`). Still requires
a saved key + explicit press + the existing confirmation.

**Invariants.** Stays strictly within the one sanctioned cloud exception — no new upload path; the
original-language clause is preserved for every style and asserted; no diarization.

**Verification.** In `ClaudeSummarizerTests` (URLProtocol stub): `systemPrompt(…style:.brief)`
contains the brevity instruction; `.actionItemsFocused` emphasizes action items; the schema is
byte-identical across all styles; the "do not translate" clause is present for every style. Fails
before, passes after.

### F64 — Pin important meetings to the top of the sidebar

- **Status:** open
- **Owner:** —
- **Severity:** — (feature; impact M / effort L / risk L)
- **Area:** meetings
- **Filed:** 2026-07-30 by Claude Code (feature discovery)

**Problem.** Meetings are strictly reverse-chronological (inline sorts at `MeetingStore.swift:205`
and `:280`); a reference or recurring recording sinks out of view with no way to keep it reachable.

**Proposed feature.** Add optional `pinned: Bool?` to `MeetingRecord` (`:31`, like the existing
optional `transcriptNormalized` so old indexes decode). Add a pure `MeetingOrdering.sorted(_:)`
returning pinned-first then `createdAt`-descending, and replace both inline sorts (`:205,280`) with
it. Add `MeetingStore.togglePin(id:)` via `update(id:)` (`:209`). Split the sidebar into
Pinned/Meetings and add Pin/Unpin to the row context menu (`ContentView.swift:73`).

**Invariants.** A single ordering flag in the index; audio/source tracks untouched; no
network/diarization.

**Verification.** New `MeetingOrderingTests`: a pinned July-1 meeting sorts before an unpinned
July-20 meeting; among equal pin state the newer `createdAt` wins; a fixture with no `pinned` key
still decodes. Fails before, passes after.

### F65 — Glossary auto-correction: reviewable spelling normalization toward the user's vocabulary

- **Status:** open
- **Owner:** —
- **Severity:** — (feature; impact H / effort M / risk M)
- **Area:** transcription
- **Filed:** 2026-07-30 by Claude Code (feature discovery)

**Problem.** Vocabulary reaches Whisper only as `--initial_prompt` (`VocabularyPrompt.build`) — a
soft nudge that fails on hard proper nouns — and reaches Qwen not at all
(`DictationTranscriptionEngine.supportsVocabularyPrompt` is false for Qwen,
`TranscriptModels.swift:70-72`). "Kubernetes" stays "cooper netties" in a Qwen meeting with no
recourse but manual find-replace. This is the only idea that brings custom vocabulary to the Qwen
path without any model API, sidestepping the F36 unanchored-contract risk.

**Proposed feature.** A pure `GlossaryCorrector`: given `store.vocabulary` and
`[TranscriptSegment]`, find high-confidence near-misses of each term via bounded edit-distance /
normalized-token matching and return `{segmentIndex, range, from, to}`. Reuse the CJK-safe
alphanumerics-lowercase normalizer (today private in `VocabularyPrompt.normalizedForEcho`,
`VocabularyPrompt.swift:93`, and `QwenAlignedTranscript.alignmentKey`,
`QwenAlignedTranscript.swift:77` — expose a shared one). WhisperMeet reviews proposals in a sheet
mirroring `VocabularySuggestionSheet` (`ContentView.swift:1835`), then applies. Same-language only;
never auto-applies.

**Invariants.** Local-only pure string logic; recording untouched; corrections are user-reviewed and
same-language (never translation); applying edits flips `isTranscriptEdited`, which already drops
segment overlays; no diarization.

**Verification.** New `GlossaryCorrectorTests`: "we deployed cooper netties today" + ["Kubernetes"]
→ exactly one proposed "cooper netties"→"Kubernetes"; an exact match → none; a cross-script
candidate → none; a too-distant token → none. Fails before, passes after.

### F66 — Meeting-library integrity self-check: flag missing/truncated audio without touching it

- **Status:** open
- **Owner:** —
- **Severity:** — (feature; impact M / effort M / risk L)
- **Area:** recovery
- **Filed:** 2026-07-30 by Claude Code (feature discovery)

**Problem.** `MeetingStore.loadMeetings` (`MeetingStore.swift:277`) validates only that
`meetings.json` decodes; it never confirms each `recordingPath` still points at present,
non-truncated, self-consistent audio, so a crash-truncated `meeting.wav` or a `.f32` whose byte
length disagrees with `source-tracks.json` loads silently and fails later opaquely.

**Proposed feature.** New pure `MeetingIntegrityChecker` taking a lightweight per-meeting descriptor
and returning `[IntegrityFinding]` (`.recordingMissing`, `.recordingEmpty`, `.wavHeaderUnreadable`,
`.wavTruncated(declared:actual:)`, `.sourceTrackFrameMismatch(…)`, `.durationInconsistent(…)`).
Extract the 44-byte WAV-header parse + frameCount arithmetic from
`InterruptedRecordingRecovery.swift:160-193` into a shared `WAVInspection` and reuse
`RecordingSizeEstimator`'s constants. Reads header bytes and file sizes only. Fold into
`AppModel.performStartupRecovery` (`:233`) plus an optional Settings "Verify library"; a finding
sets status to "Needs attention" and appends a message, rewriting no audio.

**Invariants.** Read-only: parses headers and stats sizes, never opens or deletes audio; only
annotates the index (itself recoverable); source-of-truth intact — it flags, never repairs by
deletion; local-only.

**Verification.** New `MeetingIntegrityCheckerTests` (temp-dir pattern from
`InterruptedRecordingRecoveryTests`): dirs with (a) a WAV header declaring more data than present,
(b) a `.f32` shorter than its manifest frameCount, (c) a missing `meeting.wav` each yield the
matching finding; a healthy dir returns `[]`. Fails before, passes after.

### F67 — Meeting tags with click-to-filter sidebar

- **Status:** open
- **Owner:** —
- **Severity:** — (feature; impact M / effort M / risk L)
- **Area:** meetings
- **Filed:** 2026-07-30 by Claude Code (feature discovery)

**Problem.** Dozens of meetings look alike in the sidebar (title, status dot, date). The only
organizing axis is free-text search over title+transcript (`ContentView.swift:36-42`), which cannot
express "show everything tagged budget". (More manual-upkeep than F59's faceted search; both can
coexist — a `tag:` token slots into `MeetingQuery` later.)

**Proposed feature.** A pure `MeetingTags` enum mirroring `RecordingMarkers`:
`normalized(_ raw: [String])` (trim, drop empties, case-insensitive dedupe keeping first spelling,
cap count/length like `MeetingStore.promptSafeTerms`, `MeetingStore.swift:245`) and
`matches(meetingTags:selected:mode:)` (AND/OR). Add optional `tags: [String]?` to `MeetingRecord`
(`:31`). Add `MeetingStore.setTags(id:_:)` via `update(id:)`. Render chips in `MeetingRow`
(`ContentView.swift:161`), a selected-tags predicate composing into `filteredMeetings`, and a
Tag/Untag context-menu item.

**Invariants.** Pure label metadata in `meetings.json`; never reads/mutates audio; no network; tags
are user labels, never speaker identity; transcription language untouched.

**Verification.** New `MeetingTagsTests`: `normalized()` dedupes case-insensitively and enforces the
cap; `matches()` is true only when the meeting carries all (AND) / any (OR) selected tags; a
`meetings.json` fixture with no `tags` key still decodes. Fails before, passes after.

### F68 — Structured transcription-failure classification and retry ergonomics

- **Status:** open
- **Owner:** —
- **Severity:** — (feature; impact M / effort M / risk L)
- **Area:** transcription
- **Filed:** 2026-07-30 by Claude Code (feature discovery)

**Problem.** `AppModel.handle(error:id:)` (`AppModel.swift:986-998`) stores an unstructured
`errorMessage` and flips to `.failed`; the single Transcribe button cannot distinguish a transient
crash (retry) from runtime-not-installed (install first) or empty/too-short audio (will fail again),
inviting blind re-runs. Concretizes the ROADMAP Ongoing "clearer errors, retry ergonomics" item.

**Proposed feature.** A pure `TranscriptionFailureClassifier` mapping WhisperCore error cases to a
`FailureCategory` carrying a plain-language explanation and a `SuggestedAction`. Map the real cases
(`runtimeNotInstalled`→`installRuntime`; `recordingNotFound`/`emptyTranscript`→`reimport`;
`processFailed`/`missingOutput`/`unreadableOutput`→`retry`; `CancellationError`→none). State
explicitly that categories like `insufficientStorage`/`audioTooShort` become reachable only if those
error cases are introduced. Attach the category in the `performTranscription` catch (`:945-949`) so
the detail renders the correct button.

**Invariants.** Pure deterministic mapping: no audio access, no language logic, local-only;
source-of-truth untouched — it classifies an existing failure. Distinct from F30.

**Verification.** New `TranscriptionFailureClassifierTests`: `runtimeNotInstalled` →
`.installRuntime`; `emptyTranscript` → `.reimport`; `processFailed` → `.retry`; `CancellationError`
→ no failure state; an unrecognized error → `.retry`. Fails before, passes after.

### F69 — App-wide keyboard command catalog + main-menu Commands + shortcuts help

- **Status:** open
- **Owner:** —
- **Severity:** — (feature; impact M / effort M / risk L)
- **Area:** accessibility
- **Filed:** 2026-07-30 by Claude Code (feature discovery)

**Problem.** Keyboard coverage is window-local and undiscoverable: the only shortcut, ⇧⌘M, is
attached to a Button inside the record pane (`ContentView.swift:388`) so it fires only when that
pane shows, and there is no `.commands`/`CommandMenu` anywhere. Concretizes ROADMAP Next candidate
#2 and the Ongoing accessibility (keyboard shortcuts) item.

**Proposed feature.** A pure `CommandCatalog`: commands (id, title, section, keyEquivalent,
modifiers, enablement predicate over a small `AppCommandState`) plus `displayShortcut(for:)`
following the `DictationKeyName.display` precedent (`DictationKeyName.swift:18`). In
`AppEntry.swift` add `.commands { }` building a Recording `CommandMenu` (Start/Stop ⌘R, Add Marker
⇧⌘M now app-wide, Cancel Recording… routed through the guarded dialog) and a Help item opening a
Keyboard Shortcuts sheet rendered from the catalog.

**Invariants.** Purely additive keyboard/menu surface; Cancel still funnels into the existing
confirmation; no audio/transcript mutation; local-only; no diarization/translation.

**Verification.** New `CommandCatalogTests`: no two commands share the same (keyEquivalent,
modifiers) — a real accessibility footgun; `displayShortcut` strings are exact; each enablement
predicate is correct for representative `AppCommandState` values (Add Marker enabled only while
recording). Fails before, passes after.

### F70 — Privacy-safe diagnostics bundle (audio- and transcript-excluded)

- **Status:** open
- **Owner:** —
- **Severity:** — (feature; impact M / effort M / risk L)
- **Area:** recovery
- **Filed:** 2026-07-30 by Claude Code (feature discovery)

**Problem.** When recovery/install/transcription misbehaves the evidence is scattered across
ephemeral `alertMessage`s, `store.startupRecoveryMessages`, the `DictationLog`, and per-recording
`source-tracks.json`, with no coherent snapshot for support and every hand-copy risking sweeping in
transcript text. Concretizes ROADMAP Next candidate #4.

**Proposed feature.** A pure `DiagnosticsBundleBuilder` handed the full per-meeting data (including
`transcriptText`, summary, vocabulary) that returns a deterministic Markdown+JSON string provably
excluding transcript text, summaries, vocabulary terms, and any absolute path outside the app
container — keeping only ids, timestamps, durations, status, `languageCode`, segment/marker counts,
byte sizes, recovery-alignment strings, and error messages. Wire a Settings "Export diagnostics…"
action writing the bundle to a user-chosen local folder; no audio copied.

**Invariants.** Local-only: writes a local file, no network; excludes transcript text and summaries
by construction; no audio copied; no diarization/language change.

**Verification.** New `DiagnosticsBundleBuilderTests`: feed a record whose `transcriptText` is
"SECRET-TRANSCRIPT" plus a vocabulary term "AcmeCorp"; assert neither string appears anywhere in the
output, the output parses as valid JSON, and two runs on identical input are byte-identical. Fails
before, passes after.

### F71 — VoiceOver labels and Dynamic Type for recording, meeting, and transcript surfaces

- **Status:** open
- **Owner:** —
- **Severity:** — (feature; impact M / effort M / risk L)
- **Area:** accessibility
- **Filed:** 2026-07-30 by Claude Code (feature discovery)

**Problem.** The primary record button, sidebar rows (`MeetingRow`), transcript segments, and
quality/marker strips have no spoken labels, and the transcript read view uses fixed point sizes
(`ContentView.swift:210,748,758,780,824`) that ignore Dynamic Type; VoiceOver reads these as bare
controls. (Labels exist only on the volume bar `:931` and delete-marker `:695`.) Concretizes the
ROADMAP Ongoing accessibility item.

**Proposed feature.** A pure `AccessibilityPhrase` module over primitives (WhisperCore cannot import
the WhisperMeet types): `meetingRow(title:statusRaw:duration:)` → "Team sync, transcript ready, 42
minutes"; `recordButton(isRecording:isBusy:)`; `marker(label:offset:)` (reusing
`TranscriptFormatter.timestamp`); `levelMeter(channel:level:)`. Attach via
`.accessibilityLabel/Value/Hint` in `ContentView.swift` and replace fixed font sizes in the read
view with semantic text styles / `@ScaledMetric`.

**Invariants.** Read-only: labels describe state, never mutate audio/transcript; meeting-row
phrasing never implies identified speakers; local-only; original language echoed verbatim.

**Verification.** New `AccessibilityPhraseTests` asserting exact strings across statuses/durations
(completed + 2520s → "…, transcript ready, 42 minutes"; recorded → "…, ready to transcribe"). Fails
before, passes after. Accessibility Inspector audit is manual — state it in the log.

### F72 — Per-meeting notes field, searchable and exported

- **Status:** open
- **Owner:** —
- **Severity:** — (feature; impact M / effort L / risk L)
- **Area:** meetings
- **Filed:** 2026-07-30 by Claude Code (feature discovery)

**Problem.** The only writable per-meeting text is the transcript itself (editing diverges from
segments and drops overlays) or the Claude summary; there is no neutral scratchpad for an agenda or
attendee note tied to a recording.

**Proposed feature.** Add optional `notes: String?` to `MeetingRecord` (`MeetingStore.swift:31`).
Wire a plain notes editor into `TranscriptDetailView` (`ContentView.swift:1372`) persisting via
`update(id:)`. Two pure changes: (1) add a `notes:` parameter to `MeetingNotesExporter.markdown`
(`MeetingNotesExporter.swift:7`) emitting a "## Notes" section above "## Transcript"; (2) make notes
searchable by adding it to the `fields` array in `filteredMeetings` (`ContentView.swift:40`). Notes
are NOT included in the Claude summary payload.

**Invariants.** Index-only text; no audio read/write; local-only — notes are NOT sent on the
explicit Claude Summarize (asserted); no diarization; original language unaffected.

**Verification.** In `MeetingNotesExporterTests`: non-empty notes emit a "## Notes" section with the
text; empty/nil omits it. A `TextSearch`-level test that a note-only term matches once notes is in
the `fields` array. Both fail before, pass after.

### F73 — Second opinion: re-transcribe with the other engine and compare divergences

- **Status:** open
- **Owner:** —
- **Severity:** — (feature; impact H / effort H / risk M)
- **Area:** transcription
- **Filed:** 2026-07-30 by Claude Code (feature discovery)

**Problem.** `beginTranscription` (`AppModel.swift:788`) runs one engine and `apply(result:)`
overwrites the transcript; when a user distrusts a passage there is no way to get the other
installed engine's read and see where they disagree — even though Whisper (silence-hallucination)
and Qwen (looping) have complementary failure modes, so diffing them is exactly how you catch an
error.

**Proposed feature.** A pure `TranscriptComparison` aligning two `[TranscriptSegment]` by
time-overlap and normalized text, yielding agreeing vs diverging spans carrying both engines' text
(degrade to text-only alignment when one side has no timestamps — note the dependency on F30 for the
Qwen side). WhisperMeet adds a "Second opinion" action running the non-selected installed engine on
the same read-only `meeting.wav` (honoring the `activeTranscriptionID` single-run guard), then a
comparison sheet where the user replaces or keeps the stored transcript.

**Invariants.** Both engines only READ the WAV (source-of-truth safe, retryable); local-only; both
run original-language transcribe; one transcription at a time preserved; no diarization; overwrite
is an explicit user choice like the existing re-transcribe.

**Verification.** New `TranscriptComparisonTests`: identical inputs → all-agree, zero divergences;
one differing word in an overlapping segment → exactly one divergence span carrying both texts;
disjoint timelines → handled without crashing, marked non-overlapping. Fails before, passes after.

### F74 — Compact recording HUD overlay for backgrounded meetings

- **Status:** open
- **Owner:** —
- **Severity:** — (feature; impact M / effort M / risk M)
- **Area:** ui
- **Filed:** 2026-07-30 by Claude Code (feature discovery)

**Problem.** When WhisperMeet is backgrounded during a meeting the user has no glanceable
confirmation the recording is healthy — elapsed time, level, and at-risk warnings live only inside
`ContentView`'s live panels. (Status role overlaps F62's menu bar; if only one background-awareness
feature is funded, prefer F62 — this is the passive-glance complement.)

**Proposed feature.** A `RecordingOverlay` mirroring `DictationOverlay` (reuse `NonActivatingPanel`,
`ignoresMouseEvents`, bottom-center placement, `DictationOverlay.swift:8-11,55,61-70`) driven by
`AppModel.recordingState/recordingMeter/recordingHealth`. Core in WhisperCore:
`RecordingHUDState.make(isRecording:isStopping:elapsedSeconds:health:level:)` returning
(elapsedText, statusLine, topWarning?, level) where `topWarning` selects the single most-severe item
from `RecordingHealthSnapshot`, plus `shouldPresent(isRecording:appIsActive:)` (show only while
recording AND backgrounded).

**Invariants.** Display-only overlay (`ignoresMouseEvents`, non-key panel): reads state, never
mutates/deletes audio; no new capture; local-only; no diarization/translation.

**Verification.** New `RecordingHUDStateTests`: recording with
`[.lowStorage, .systemAudioNotDetected]` surfaces the higher-severity warning; elapsed 323s →
"5:23"; `shouldPresent` false when active, true when backgrounded; stopping shows a finishing state.
Fails before, passes after.

### F75 — Local automatic backups with hash verification and retention

- **Status:** open
- **Owner:** —
- **Severity:** — (feature; impact H / effort H / risk M)
- **Area:** recovery
- **Filed:** 2026-07-30 by Claude Code (feature discovery)

**Problem.** Everything lives under one Application Support folder on one volume; a dying disk or
errant delete takes all of it. `BackupJSONStore` protects one index file from corruption, not the
library from loss. Concretizes ROADMAP Next candidate #3.

**Proposed feature.** Put the decidable logic in WhisperCore as pure functions: (a)
`BackupPlan.compute(source:destination:)` over file descriptors (relativePath, size, contentHash) →
copy vs already-current; (b) `BackupRetention.prune(generations:policy:)` → which destination
generations to drop (keep-N or keep-N-days, modeled on `DictationLog`'s capped-history logic); (c)
`BackupVerification` comparing expected vs actual hash after copy. A thin WhisperMeet
`BackupCoordinator` does the `FileManager` copy in `Task.detached` from `store.rootDirectory`
(`MeetingStore.swift:111`), destination chosen in Settings, triggered on quit or a schedule; it
never writes the source, with a pre-copy free-space check reusing `RecordingSizeEstimator`.

**Invariants.** Local-only: a user-selected local folder, no cloud path; the source is never
modified or deleted — retention prunes only destination copies under the user's explicit policy; no
diarization/language involvement.

**Verification.** New `BackupPlanTests` + `BackupRetentionTests`: an unchanged (same-hash) file is
skipped, a changed one scheduled, a new one copied; keep-3 retention prunes exactly the 4th-oldest
and older; a post-copy hash mismatch surfaces as a verification failure. Fails before, passes after.

### F76 — Suggest a meeting title from the local Calendar

- **Status:** open
- **Owner:** —
- **Severity:** — (feature; impact M / effort M / risk M)
- **Area:** meetings
- **Filed:** 2026-07-30 by Claude Code (feature discovery)

**Problem.** New recordings get a generic auto-title (`AppModel.swift:251/279/290`), so the sidebar
fills with placeholder names the user renames by hand, even when a real calendar event's title is
the obvious name and already exists on the Mac.

**Proposed feature.** A pure `CalendarTitleMatcher` over a framework-free
`CalendarEventSummary { title; start; end }`: `bestTitle(forRecordingStartedAt:in:tolerance:)`
returns the event whose [start,end] contains the recording start, else the closest within tolerance,
resolving overlaps deterministically (earliest start wins, documented). Thin WhisperMeet wiring
reads EventKit (a new dependency — add to the WhisperMeet target in `Package.swift`) to build the
summaries and pre-fills the editable title in `RecordMeetingView` (`ContentView.swift:198`).
Suggestion only; if access is denied, fall back to the existing auto-title with zero behaviour
change.

**Invariants.** Reads the local EventKit store only — no network/upload; audio untouched; associates
a TITLE only, not speaker identity; transcription language unaffected. Honest cost: a
privacy-sensitive Calendar permission and a new framework, degrading silently when denied.

**Verification.** New `CalendarTitleMatcherTests`: a start inside an event returns its title; a
start 2 min before an event (within tolerance) returns it; no nearby event returns nil; two
overlapping events resolve to the earliest-start title. Fails before, passes after. EventKit wiring
verified manually; state it in the log.

### F77 — Per-segment re-run: re-transcribe a single flagged span

- **Status:** open
- **Owner:** —
- **Severity:** — (feature; impact M / effort H / risk M)
- **Area:** transcription
- **Filed:** 2026-07-30 by Claude Code (feature discovery)

**Problem.** When the quality banner flags one segment, the only remedies are hand-editing or
re-running the whole meeting; there is no way to re-transcribe just that time range (e.g. forcing a
language on a code-switch stumble, or trying the other engine on a 6-second span).

**Proposed feature.** Two pure WhisperCore pieces: (a) `SegmentAudioRange` — given a segment's
start/end, sample rate, and the fixed 16-bit-mono PCM layout `WAVWriter` defines (44-byte header,
`WAVWriter.swift:7`; 2 bytes/sample), compute the byte range to slice; (b) `TranscriptSegmentSplice`
— replace `segment[i]` with the re-run's segments, re-anchoring timestamps by the clip's start
offset and re-flowing order/ids. WhisperMeet reads that byte range from `meeting.wav`, writes a temp
clip via `WAVWriter.wavData`, runs the chosen engine/language on the clip, and splices back. Note:
this introduces the codebase's first WAV sub-range READ (`WAVWriter` is write-only today), and on
Qwen it depends on reliable segment timestamps that F30 shows can be dropped.

**Invariants.** Reads `meeting.wav` only and writes a disposable temp clip (recording is the source
of truth, untouched, retryable); local-only; original language preserved; no diarization;
user-initiated per segment.

**Verification.** New tests: `SegmentAudioRange` maps t=[1.0,2.0] at 16 kHz to byte offsets
44+1.0×16000×2 through 44+2.0×16000×2; `TranscriptSegmentSplice` replacing index 1 of a 3-segment
transcript with two re-run segments yields 4 segments, start-offset-anchored and strictly ordered.
Fails before, passes after.

---

*Board created 2026-07-30. Seeded from the review of `e9bca61` and `64455ec`.* *F28–F37 added
2026-07-30 from the two-axis review of `7e048ff...HEAD`.* *F38–F54 (defects) and F55–F77 (features)
added 2026-07-30 from a codebase-wide fix sweep and a multi-lens feature discovery, each finding
verified against the working tree.*
