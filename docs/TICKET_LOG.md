# Ticket log

Append-only record of every ticket closed. Newest first. Open work lives in
[`TICKETS.md`](TICKETS.md).

**Write real evidence, not intent.** Paste actual command output. "Tests pass" is not a log entry;
`✔ Test run with 178 tests passed` is. If a fix could not be verified the usual way, say exactly
what was skipped and why — an honest gap is useful, a glossed one is a trap for the next agent.

Never edit or delete an existing entry. If an entry turns out to be wrong, append a new one that
corrects it and say which entry it supersedes.

## Entry template

```markdown
## F<n> — <summary>

- **Outcome:** fixed | wontfix | invalid | duplicate
- **Closed:** YYYY-MM-DD by <agent/session>
- **Commits:** `<sha>`

**Root cause.** Why it happened, not just what changed.

**Fix.** What changed, and why that is the right layer to change.

**Evidence.**

​```text
<real command output — failing test before, passing after, build, real-model run>
​```

**Gaps.** Anything not verified, and why. Write "none" only if that is true.
```

---

## F50 — Hold-mode dictation has no capture cap or stuck-listen watchdog

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code (Opus 4.8) / simonwang
- **Commits:** `af8ddbd` (claim), `e8a0692` (fix)

**Root cause.** Two independent ways for hold-mode dictation to wedge in `.listening` with the mic
hot. (1) `DictationController` armed no timeout on `.listening`; capture ended only on a matching
`handlePressEnd`, so a dropped release edge left it listening forever while `MicDictationRecorder`
appended every chunk to an unbounded `samples` array (~64 KB/s at 16 kHz Float32). (2) On
`.tapDisabledByTimeout`/`.tapDisabledByUserInput`, `HotkeyMonitor` re-enabled the tap but dropped
the events during the disabled window; the modifier path self-heals from absolute flag state, but
the keyDown/keyUp path used for F-keys (an explicitly recommended trigger) did not — a missed key-up
left `keyDown = true` and every subsequent press was swallowed by the autorepeat guard.

**Fix.** Added `DictationCaptureWatchdog` (armed on `.listening`, cancelled on finalize/disable) that
finalizes the session after the maximum capture duration, so a missed release self-recovers to idle.
Backed it with a hard-capped `BoundedAudioSampleBuffer` (`WhisperCore`, pure/`Sendable`) as an
independent backstop against unbounded queue growth if the main actor can't fire the watchdog in
time. `HotkeyMonitor.recoverFromDisabledTap()` resynchronizes `keyDown` from live hardware key state
(`CGEventSource.keyState`) on tap re-enable. Introduced injection seams (`DictationRecording` /
`DictationOverlayPresenting` protocols, injectable `logStore`/timeout/sleep, `activateOnInit`) so the
recovery paths are testable headlessly without mic/Accessibility hardware.

**Evidence.**

The two behavioral regressions fail with the fix neutralized (watchdog `arm()` and the key-state
resync temporarily disabled), reproducing the exact wedge — controller stuck in `.listening` with
the recorder still hot, and the F-key press swallowed after a missed release:

```text
✘ Test "A missed dictation release stops recording and recovers the controller to idle" recorded an issue at DictationControllerWatchdogTests.swift:88:5: Expectation failed: (recorder.stopCount → 0) == 1
✘ Test "A missed dictation release stops recording and recovers the controller to idle" recorded an issue at DictationControllerWatchdogTests.swift:89:5: Expectation failed: !((recorder → ...FakeDictationRecorder).isRecording → true → true)
✘ Test "A missed dictation release stops recording and recovers the controller to idle" recorded an issue at DictationControllerWatchdogTests.swift:90:5: Expectation failed: (controller.status → .listening) == .idle
✘ Test "A disabled event tap resynchronizes a missed F-key release" recorded an issue at HotkeyMonitorRecoveryTests.swift:36:5: Expectation failed: (presses.value → 1) == 2
✘ Test run with 2 tests failed after 0.025 seconds with 4 issues.
```

They pass with the fix restored:

```text
✔ Test "A missed dictation release stops recording and recovers the controller to idle" passed after 0.007 seconds.
✔ Test "A disabled event tap resynchronizes a missed F-key release" passed after 0.025 seconds.
✔ Test run with 2 tests passed after 0.025 seconds.
```

The full quality gate (build + both suites) passed:

```text
Build complete! (0.42s)
✔ Test run with 183 tests passed after 1.075 seconds.
```

**Gaps.** The watchdog's real-clock firing at the 120 s ceiling is proven only with an injected
instant `sleep` (unit-verified in `watchdogFinalizesStuckCapture` and the controller integration
test), not by a 120 s wall-clock hold on hardware. No model runtime/adapter was touched, so no
real-model run applies.

## F48 — `AudioCaptureEngine.stop()` could wedge the engine after a finalization failure

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Codex / root
- **Commits:** `69def10`, `9a9731a`

**Root cause.** `AudioCaptureEngine.stop()` registered `defer { reset() }` only after both raw-track
writers finished. If either writer threw while closing its file handle, `stop()` exited before
resetting the active stream. Every later `start()` therefore hit the already-active guard and
returned without starting capture or installing health/level callbacks, while the app could still
show a recording state.

**Fix.** Registered reset immediately after `stop()` validates the active capture session, so every
exit path releases the stream. A track-finalization error now also invokes the existing best-effort
partial-track preservation path before propagating the original error. Added a headless
`WhisperMeetTests` target and a narrow injected capture seam: the regression makes track
finalization throw, proves preservation runs, then proves a subsequent `start()` proceeds and
delivers both callbacks without accessing microphone/screen hardware or user data. Updated
`CLAUDE.md` to document that test boundary.

**Evidence.**

The regression failed before the lifecycle fix:

```text
◇ Test "A failed stop releases the capture session and preserves partial tracks" started.
✘ Expectation failed: expected error of type AudioCaptureError,
  but "finishingTrack" of type ExpectedFailure was thrown instead
✘ Expectation failed: (stopCount → 2) == 1
✘ Expectation failed: preservedPartialTracks
✘ Test run with 1 test failed after 0.001 seconds with 3 issues.
```

It passed after the fix and after the review-strengthened restart/callback assertions:

```text
Build complete! (1.11s)
◇ Test "A failed stop releases the capture session and preserves partial tracks" started.
✔ Test "A failed stop releases the capture session and preserves partial tracks" passed after 0.001 seconds.
✔ Test run with 1 test passed after 0.001 seconds.
```

The final repository quality gate passed:

```text
[1/4] Checking the candidate diff for whitespace errors
[2/4] Running the complete test suite
✔ Test run with 179 tests passed after 1.058 seconds.
[3/4] Building production code with warnings as errors
Build complete! (12.39s)
[4/4] Packaging and signing WhisperMeet.app
Build complete! (11.15s)
.build/WhisperMeet.app: replacing existing signature
/Users/simonwang/Documents/Whisper/.build/WhisperMeet.app
Quality check passed.
```

Two-axis review initially found an outdated Core-only testing rule and incomplete restart coverage.
After the documentation and test corrections, both reviewers reported no remaining standards or
F48/spec findings.

**Gaps.** No live microphone/screen recording was started: the failure requires a writer close
error, which the injected test reproduces deterministically without risking a user's recording.
No model run was applicable because F48 does not touch a model adapter or runtime helper. The first
sandboxed test attempt could not compile because Swift's module cache was outside the writable
workspace; the approved rerun used a writable temporary compiler cache and produced the red/green
results above.

---

## F29 — The benchmark table in `CHANGELOG.md` could not be reproduced from the repo

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code
- **Commits:** `c2c141c`

**Root cause.** The two-engine table published in the F24 entry was produced by a driver written in
a session scratchpad and never committed. Nothing in the repo could re-run or falsify it — the same
claim-without-artifact pattern that let F24 itself hide for so long. `Scripts/bench/benchmark.py`
looks like the relevant tool but is not: it loads candidate models with its own loaders to compare
engine families, and never speaks to the shipped helper subprocesses.

**Fix.** Added `Scripts/bench/dictation-ab.py`. It spawns both **production** helpers with the exact
argv `WarmWhisperDictationEngine` / `WarmQwenDictationEngine` use, including the Qwen offline
environment, and speaks the real `{"wavPath", "language", "initialPrompt"}` wire protocol. That is
the distinction that matters: a model-level benchmark cannot see F24, but this script fails loudly
on it. The `CHANGELOG.md` entry now cites the command and states which numbers are deterministic.

**Evidence.**

The script caught a real stale-helper condition on its first run — the installed Whisper helper
still predated the F24 fix, because the app syncs only the selected engine's helper and Qwen was
selected (that is F25, reproduced live):

```text
== turbo ==
turbo: helper never reported ready.
Detected language: English
```

After syncing the installed helper from the app bundle the way the app itself does (`80e86bdaf487` →
`a1d671e3e6da`), the full comparison ran:

```text
| engine | cold start | warm per clip | en | zh | code-switch |
|---|---|---|---|---|---|
| Qwen3-ASR 1.7B | 2.2 s | 0.31 s | 0.000 | 0.000 | 0.000 |
| Whisper Turbo | 9.5 s | 1.39 s | 0.025 | 0.049 | 0.000 |
```

Compared against the originally published table (2.8 s / 8.6 s cold, 0.36 s / 1.43 s warm): the
**error rates reproduced exactly**, and latency moved about 15 %. The changelog now says so rather
than implying the timings are fixed.

Suite unaffected and still green:

```text
✔ Test run with 178 tests passed after 1.100 seconds.
```

**Gaps.** Two, both now stated in the changelog rather than hidden:

1. `Scripts/bench/clips/*.wav` are **gitignored** — only `references.json` is tracked. A fresh
   checkout must run `Scripts/bench/generate_clips.sh`, which re-synthesises the clips with macOS
   `say`. A different macOS version or voice set will produce different audio, so error rates are
   reproducible for *a given clip set*, not universally. Committing the clips would close this
   properly; it was not done here because it adds binary audio to the repo and deserves its own
   decision.
2. No failing-test-first evidence, because this ticket changed tooling and documentation, not
   product behaviour. The definition of done requires that test for behaviour changes; asserting one
   here would be theatre.

---

## F24 — Whisper dictation helper polluted its own JSON protocol with stdout chatter

- **Outcome:** fixed
- **Closed:** 2026-07-30 by Claude Code
- **Commits:** `64455ec`, `5975d02` (doc correction)

**Root cause.** `Scripts/whisper_dictate_server.py` passed `verbose=False` to
`mlx_whisper.transcribe`. Whisper documents `False` as *"minimal details"*, and the library guards
its prints with `if verbose is not None` — so `False` still writes `Detected language: X` to
**stdout**, which is the wire carrying this helper's newline-delimited JSON protocol. Verified
against the live openai/whisper source per `AGENTS.md` and against the installed
`mlx_whisper/transcribe.py:175`.

Auto-detect is the default dictation language, so this fired on warm-up *and* on every automatic
request. `WarmWhisperDictationEngine.ensureRunning` read the chatter line instead of
`{"ready": true}`, failed both decodes, and threw `"Dictation helper failed to start."`
`FallbackDictationEngine` then silently dropped to the batch Whisper CLI. **Whisper Turbo — the
default dictation engine — had never actually used its warm path.** Text still came out, which is
why it went unnoticed for so long. Qwen was never affected; its helper only writes JSON.

**Fix.** Two layers, because either alone leaves the failure class open:
1. The helper passes `verbose=None`, the only value Whisper treats as silent.
2. `WarmWhisperDictationEngine.readLine` skips stdout lines that are not JSON objects, recording
   them as diagnostics. The skip happens inside the watchdog window on purpose, so chatter cannot
   buy a stalled helper extra time. Without this, one stray line desyncs the stream permanently —
   every later response answers the previous request.

**Evidence.**

Raw stdout captured from the *installed* runtime before the fix:

```text
--- raw stdout lines during warm-up ---
  [0] 'Detected language: English\n'
  [1] '{"ready": true}\n'
--- request with language=null (app default) ---
  [0] 0.84s 'Detected language: English\n'
  [1] 1.56s '{"text": "Can you send me the quarterly report by Friday afternoon?", ...}'
```

New tests failing before the fix:

```text
✘ Test "Whisper dictation helper keeps stdout pure JSON when the model auto-detects language"
  ↳ non-JSON line on the wire: Detected language: English
  ↳ Expectation failed: (lines.count → 4) == 2
✘ Test run with 1 test failed after 0.032 seconds with 4 issues.
```

Passing after:

```text
✔ Test "Helper chatter on stdout is skipped instead of being read as a protocol message" passed
✔ Test "Whisper dictation helper keeps stdout pure JSON when the model auto-detects language" passed
✔ Test run with 178 tests passed after 1.095 seconds.
```

Real installed models, all ten `Scripts/bench/clips`, `language: null` — the comparison that could
not run before because Turbo never reached readiness:

```text
qwen3-asr-1.7b-8bit    cold-start   2.8s | warm/clip 0.36s | en 0.000 zh 0.000 cs 0.000
turbo                  cold-start   8.6s | warm/clip 1.43s | en 0.025 zh 0.049 cs 0.000
```

Release build, packaging, and install:

```text
Build complete! (10.82s)          # swift build -c release -Xswiftc -warnings-as-errors
/Applications/WhisperMeet.app: valid on disk
/Applications/WhisperMeet.app: satisfies its Designated Requirement
whisper_dictate_server.py  app=a1d671e3e6da repo=a1d671e3e6da
```

**Gaps.** Turbo's non-zero error rates are mostly formatting rather than misrecognition (`ten`→`10`,
`三点`→`3点`); the single true error was `纪要`→`记要`. The corpus is small and synthetic, so treat the
table as a smoke test of the wire path, not a general accuracy claim — the real microphone
comparison is filed as F27. The installed `Runtime/whisper_dictate_server.py` was still the pre-fix
copy after install because only the selected engine's helper is synced; filed as F25.

---

*Log created 2026-07-30.*
