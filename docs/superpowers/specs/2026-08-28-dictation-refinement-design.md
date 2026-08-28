# Dictation refinement with the local AI model (F200)

**Date:** 2026-08-28
**Status:** Approved design, pre-implementation
**Ticket:** F200 (next free ID per `docs/TICKETS.md`)

## What this is

An opt-in pass that hands the freshly transcribed Quick Dictation text to the
already-installed local Qwen model for a light-touch cleanup — grammar,
punctuation, capitalization, filler-word removal — before the text is pasted.
Speed is protected by a hard, length-scaled time budget: if the model does not
answer in time, the raw transcript is delivered exactly as today and the
refinement is abandoned.

This deliberately revisits a v1 non-goal. `docs/QUICK_DICTATION_DESIGN.md`
("Non-goals (v1)") rejected AI cleanup because it "adds latency + network;
breaks the local-instant feel". Both objections are answered here: the model is
the on-device Summarizer runtime (no network), and the time budget caps the
latency cost at a bounded, modest worst case.

## Decisions taken (with the user, 2026-08-28)

1. **Rewrite level: light touch.** Fix grammar, punctuation, capitalization,
   obvious transcription slips; remove fillers ("um", "you know"). Never
   restructure sentences; the user's wording and order stay theirs.
2. **Latency rule: time-budget fallback.** Refinement races a budget derived
   from text length. A miss delivers the raw transcript immediately; the user
   never waits on the model beyond the budget.
3. **Default: opt-in toggle**, off. New "Refine with local AI" toggle in
   Dictation settings.
4. **Model: reuse the installed Summarizer model** (`mlx-community/Qwen3-8B-4bit`
   on ≥16 GiB Macs, `Qwen3-4B-4bit` otherwise). No new download; a warm
   resident server with the same idle-eviction lifecycle as the Whisper
   dictation model.

## Alternatives considered and rejected

- **Apple Foundation Models framework** (macOS 26 `SystemLanguageModel`): zero
  RAM/install cost, but diverges from the requirement to use the current local
  model, adds an Apple-Intelligence availability gate, and forks the runtime
  story. Worth revisiting later.
- **Refine after delivery** (paste raw instantly, refined copy only in the log
  or clipboard): zero latency risk, near-zero value.
- **Per-call subprocess** (current `LocalSummarizer` shape): a fresh
  `mlx_lm.load` per call costs seconds, so the budget would miss nearly every
  time; the feature would effectively never apply.
- **Inject raw, then replace in place**: replacing already-typed text in
  arbitrary target apps is fragile and can clobber user edits.

## Architecture

Five pieces, following the established WhisperCore/WhisperMeet split (pure,
`Sendable`, headlessly testable logic in WhisperCore; AppKit/process wiring in
WhisperMeet — the refine engine's process IO mirrors `WarmWhisperDictationEngine`,
which already lives in WhisperCore):

### 1. `Scripts/refine_server.py` — resident refine helper

- Lives in the **Summarizer runtime** (`Runtime/Summarizer`), installed by
  `setup-local-summarizer.sh` alongside `summarize_local.py` /
  `correct_local.py`; same venv, same pinned model directory, same offline env
  (`HF_HUB_OFFLINE=1` etc.).
- Resident process speaking newline-delimited JSON over stdin/stdout, the
  exact pattern of `whisper_dictate_server.py`: loads the model once, runs a
  small prewarm generation, prints `{"ready": true}`, then serves requests.
- Request: `{"text": "...", "language": "en" | "zh" | null}`.
  Response: `{"text": "..."}` or `{"error": "..."}`. Non-JSON stdout chatter
  must be avoided or filtered (protocol-desync lesson from
  `WarmWhisperDictationEngine.isProtocolMessage`).
- Generation: chat template with `enable_thinking=False`, greedy (`temp=0.0`),
  `max_tokens` proportional to input length (bounds runaway generations, which
  also bounds how long an abandoned request can occupy the server).
- The system prompt is **built in Swift** and sent with each request (house
  pattern: Swift is the single source of truth for prompts). Content: correct
  grammar, punctuation, and capitalization; remove filler words; keep the
  speaker's wording and sentence order; same language as the input — never
  translate; never add content or answer the text as if it were a question;
  output the corrected text only, no quotes, no commentary.

### 2. `WarmRefineEngine` (WhisperCore) — process host

Structural sibling of `WarmWhisperDictationEngine`:

- Serial-queue process IO bridged to async via checked continuations;
  `liveLock`-guarded off-queue termination; stderr drained continuously.
- `ensureRunning()` (lazy start), `shutdown()`, `retire()`.
- Timeouts: warm-up "ready" read capped at 300 s (model already on disk — no
  download path); per-request read capped at 30 s (the *budget* is enforced by
  the caller; this watchdog only prevents a wedged child from hanging the
  queue forever).
- New wire types `RefineRequest` / `RefineResponse` beside the existing
  `DictationRequest` / `DictationResponse` in `DictationProtocol.swift`.

### 3. `DictationRefinePolicy` (WhisperCore) — pure decision + guardrails

All decisions are pure functions, fully unit-tested.

**Attempt/skip decision** — refinement is skipped (raw text delivered, no
model call) when:

- the toggle is off, the runtime is not installed, or the Mac is Intel;
- the refiner is still busy with a previous dictation's abandoned generation
  (never queue behind an overrun);
- the text is longer than ~60 words (would nearly always miss the budget);
- the text is empty (nothing to refine).

**Budget** — `B = 0.7 s + 30 ms × wordCount`, capped at 2.0 s. Constants live
in the policy and are pinned by tests. Honest framing: a missed budget means
delivery lands up to `B` *later* than today, so `B` stays modest by design.

> **Revision (2026-08-28, post-measurement).** The real installed model
> (Qwen3-8B-4bit on an 18 GiB Apple-silicon Mac) measured a ~1.0–1.3 s floor on
> short requests, so the 0.7 s base missed every time. Constants shipped as
> **base 1.2 s + 30 ms/word, capped at 2.5 s** — the measured runs then land
> within budget with 200–350 ms headroom. The hard-ceiling framing is
> unchanged; only the numbers moved, on evidence.
(CJK text has no space-delimited words; for majority-CJK text — as decided by
`TranscriptLanguage.dominant(of:)` — the budget and the length cap use
`wordCount = ceil(nonWhitespaceCharacterCount / 2)` instead of
space-delimited words.)

**Acceptance guardrails** — the model's output is *rejected* (raw delivered)
unless all hold, mirroring the F165 verbatim-guard ethos of never trusting
LLM output blindly:

- non-empty after trimming;
- surrounding quotes or code fences are stripped first; if stripping changes
  the text, re-check the remaining rules against the stripped form;
- length within 0.5×–1.5× of the input (light-touch edits shouldn't move
  length much; filler removal shrinks a little);
- dominant script unchanged — `TranscriptLanguage.dominant(of:)` on input and
  output must agree (translation/hallucination tripwire, reusing the existing
  F32 heuristic);
- single-line: internal newlines collapse via the existing
  `DictationTextCleanup.clean` applied to the refined text too.

### 4. `DictationController` wiring (WhisperMeet)

In `transcribe(clip:)`, after `DictationTextCleanup.clean` and the
prompt-echo guard, before `finish(text:)`:

- Consult the policy. On *skip*: unchanged behavior.
- On *attempt*: show the overlay's new `.refining` ("Polishing…") phase, race
  `WarmRefineEngine` against the budget (task + timeout). Budget miss, engine
  error, or guardrail rejection → deliver raw. Success → deliver refined.
- An abandoned generation is *not* killed (bounded by `max_tokens`); the
  server finishes and the stale result is discarded. The busy-skip rule above
  keeps the next dictation from queueing behind it. A stale response arriving
  later must be discarded by request correlation (monotonic request id), not
  by killing the child.
- **Prewarm**: `ensureRunning()` fires (fire-and-forget) when the toggle turns
  on, when dictation is enabled with the toggle on, and on hotkey press-down —
  the model loads while the user is still speaking. The first dictation after
  an idle eviction may still miss the budget → raw; acceptable by design.
- **Lifecycle**: the existing 5-minute idle-eviction timer, `disable()`, and
  app teardown shut down the refiner alongside the Whisper model. Turning the
  toggle off shuts down the refiner immediately.

### 5. Settings + overlay + log (WhisperMeet)

- **Settings** (`DictationView`): "Refine with local AI" toggle following the
  `@Published` + `UserDefaults { didSet }` pattern on `DictationController`
  (key `dictationRefineEnabled`). Disabled with explanation when the
  Summarizer runtime is missing (reusing the existing install affordance) or
  on Intel Macs. An older runtime lacking `refine_server.py` follows the
  established staleness pattern (`isCorrectionHelperInstalled` precedent): an
  `isRefineHelperInstalled` check gates the toggle and prompts the existing
  update/repair flow.
- **Overlay** (`DictationOverlay`): new `.refining` phase, label "Polishing…",
  between `.transcribing` and the terminal pills. No other UI change.
- **Dictation log**: `DictationLogEntry` gains two optional, backward-
  compatible fields — `rawText: String?` and `refinement: Refinement?` where
  `Refinement` is `refined | rawTimeout | rawRejected | rawError` — populated
  only when an attempt ran. Old log files decode unchanged (optional fields
  decode as nil via `decodeIfPresent`). `DictationView` history can later
  surface "what the model changed"; rendering improvements are out of scope.

## Data flow (happy path)

```
hotkey down ──────────────► prewarm refine server (parallel with speech)
hotkey up → WAV → WarmWhisperDictationEngine.transcribe
        → DictationTextCleanup.clean → prompt-echo guard
        → policy: attempt(budget B)          [overlay: Polishing…]
        → WarmRefineEngine.refine(text) ─┬─ answers within B → guardrails pass
                                         │        → deliver refined text
                                         └─ miss/error/reject
                                                  → deliver raw text
        → finish(text) → TextInjector (clipboard + ⌘V)   [overlay: Pasted]
        → DictationLogStore.record(text, outcome, rawText, refinement)
```

## Error handling

- Refine server fails to start / crashes: policy sees "not running", skips;
  raw path unaffected. Next prewarm retries lazily.
- Timeout: raw delivered at `t = B`; stale response later discarded by
  request id.
- Guardrail rejection: raw delivered; outcome logged as `rawRejected` for
  auditability.
- Runtime uninstalled while toggle on: toggle-side gating re-checks
  `isRefineHelperInstalled` on enable; mid-flight, engine start failure falls
  back to raw.
- The refiner can never blank a dictation: every failure mode delivers the
  raw transcript; the empty-transcript path remains governed by the existing
  session state machine.

## Invariants preserved

- Dictation never touches the network (runtime runs `HF_HUB_OFFLINE=1`).
- Original language only, never translate (prompt constraint + dominant-script
  guardrail).
- Ephemeral scratch data only; `Recordings/` untouched.
- Raw-path latency is untouched when the toggle is off or the policy skips —
  the refine code must not sit on the toggle-off path at all.
- Worst-case added latency with the toggle on is `B ≤ 2.0 s`, bounded and
  documented.

## Memory footprint (documented cost, not a blocker)

While warm: Whisper turbo ~1.6 GB + Qwen3-8B-4bit ~4.5 GB (or 4B ~2.3 GB).
Both evict after 5 idle minutes. The toggle copy in Settings should mention
the RAM cost plainly.

## Testing

Unit (WhisperCore, headless — runs in `Scripts/quality-check.sh`):

- Policy: budget math (word- and CJK-character-based), skip rules (off /
  missing runtime / busy / >60 words / empty), constants pinned.
- Guardrails: acceptance and each rejection reason; quote/fence stripping;
  CJK dominant-script mismatch; length-ratio bounds.
- Wire protocol: `RefineRequest`/`RefineResponse` encode/decode; ready-line
  handling; error payloads.
- Log: `DictationLogEntry` backward-compatible decode (old JSON without the
  new fields), new-field round-trip.

Wiring (WhisperMeetTests, seam-injected fakes — house pattern from
`CorrectionWiringTests` / dictation watchdog tests):

- Toggle off → refine engine never touched.
- Attempt + fast fake → refined text reaches `TextInjector` and the log.
- Attempt + slow fake → raw text delivered within budget + ε; stale result
  discarded; log records `rawTimeout`.
- Busy fake → skip, raw delivered, no queueing.
- Guardrail-violating fake output → raw delivered, `rawRejected` logged.
- Prewarm called on press-down when enabled; not called when toggle off.
- Idle eviction and `disable()` shut the refiner down.
- Settings gating: toggle disabled without runtime / with stale runtime.

Manual (not CI, recorded in the ticket): real-model latency sanity on a Mac
running the 8B model — a two-sentence dictation should refine within budget
on a warm server; a 60+ word dictation should skip.

## Non-goals

- No streaming or partial injection; no "readable rewrite" mode; no cloud
  refinement; no change to meeting transcripts or their correction flows; no
  per-app behavior; no new hotkeys; no history-UI redesign.
