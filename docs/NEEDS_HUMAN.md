# Needs human

Letters to you, not a work queue — each is something no test and no agent can do, with a
**What I need from you:** line saying exactly what. The *ticket* for each lives in
[`TICKETS.md`](TICKETS.md) (`blocked`) or [`TICKET_LOG.md`](TICKET_LOG.md) (closed `partial`), so
nothing here is the only record of anything. Conventions are in
[`../AGENTS.md`](../AGENTS.md).

**Rebuilt 2026-09-19 (whisper-37).** This file had drifted badly: eight letters, five of whose asks
were already answered, while four live questions had no letter at all and one — F188's — had never
been written down anywhere you read. The answered ones are summarised under
[Settled](#settled-nothing-needed-from-you) at the bottom rather than deleted. Two of them turned
out *not* to be answered and are still here, now with the board tickets they always should have had
(**F351**, **F352**).

## Answered 2026-09-24 — you said "问题全部按推荐"

You answered the eleven questions from whisper-0a40's board triage with every recommended answer.
What that settles, so no one asks again:

- **F299** — drop the blinded-reviewer value gate; close as Not planned once the spec's gate line and
  the scorecard row say so.
- **F351** — no 4-bit download; closed won't-fix.
- **F352** — keep what ships (text removed one week after a delete; Forget History removes it at
  once); closes as invalid with F450.
- **Read-only counts from your own data** — yes to F201's dictation-log report and to F347 using your
  meetings' system-audio tracks as the answer key; yes to the optional F349 recount and F294 log
  read. Counts only, never transcript text.
- **Screen control, scratch copy only** — yes, after F434 is fixed, an agent may press Restore Library
  in a throwaway scratch app (F353). For F230 the accessibility-tree read of your real app was left
  as your call; with "all recommended" and no recommendation given, it stays **off** until you say
  otherwise.
- **F230** — use one of your own multi-person meetings.
- **F315** — no window-targeted UI automation now; closed won't-fix.
- **F455** — for a hand-edited meeting, Ask falls back to keyword search over the edited text.
- **F457** — block Forget History while the library is read-only, and correct its undo caption.
- **F419** — measure clipping per input channel before the downmix.
- **F439 · F440** — an agent may run the local-summarizer installer once for real, after both fixes.

The letters below still stand for what needs your hands (F355, F294, F201, F230, F428, F353's check).

## Where to start

Eight entries, over the cap of five. Rather than drop one of your unanswered questions to get under
the line, here they are in the order I would answer them. Every one is optional and nothing rots.

| | Entry | Time | Why this order |
|---|---|---|---|
| 1 | **F355** | ~3 min | Listen to one recording, and read its health note. Two audio changes landed today and no ear or eye has been near either. |
| 2 | **F294** | ~2 min | One menu-bar recording. Confirms that a windowless session's notices actually arrive. |
| 3 | **F353** | ~3 min | Press Restore Library once, on a real container. Wrongly retired earlier today — the case F288 named was never the one checked. |
| 4 | **F352 · F351** | ~2 min | Two short answers: a privacy default, and a yes/no on a download. No work either way. |
| 5 | **F201** | ~15 min | A microphone and the installed app. Dictation refinement has never been watched with real speech. |
| 6 | **F230** | ~20 min | VoiceOver, keyboard and Dynamic Type on the speaker screens. Narrowed since it was written — two of its seven checks are now covered by tests. |
| 7 | **F299 · F347 · F349** | your call | Three speaker-label questions that need your own meetings. The smallest is one command. |
| 8 | **F428** | ~2 min | Copy on your iPhone, dictate on the Mac, paste — once more, with F516 installed. The log now says what macOS handed over. |

---

## F355 — Listen to one recording, and read what it says about itself

**Status:** `blocked`. The mix gain rule changed today (F345) and every number justifying it is
synthetic. The defect was reported by ear; nothing has been heard since.

**What I need from you:** one short recording, played back — and a glance at what it says afterwards.

Two changes landed today and both need an ear or an eye, so they share this one recording.

Play something with sound through your Mac, talk over it for thirty seconds, stop, and listen to
the result. Two things to judge:

1. **Is the buzz gone?** The mechanism certainly is — below the knee the output is now bit-identical
   to an ideal linear mix, so there is no amplitude modulation left to make sidebands. But "the
   mechanism is absent" and "it sounds right" are different claims and I can only make the first.
2. **Is the overlap level comfortable?** Passages where you and the system audio are both talking
   are now **1.7 to 5.0 dB louder** than they used to be. That was your call this morning, and it is
   the honest consequence of deleting a rule that was quietly ducking whoever was already talking.
   Solo passages are unchanged to the bit.

3. **And read the meeting's health note, if it shows one.** F346 replaced "System audio was
   clipping (too loud) at times" — a sentence that said the identical thing about 139 stray samples
   and a recording that was flat-topped for a seventh of its length, and that sent an investigation
   after the wrong fault. It now reports what was measured, e.g. *"System audio reached full scale
   on 139 of 14,400,000 samples — about 1 in 103,597. That is far too few to be a level problem."*
   What I need to know is whether that reads as informative or as noise.

If something still buzzes, tell me what it sounds like and roughly when — a recording of it is not
needed and I would rather not have one.

---

## F294 — Confirm a menu-bar-only session gets its notices

**Status:** `blocked`. This ask used to live under the F257 letter, and F257 closed on 2026-09-17 —
so the question has been filed under a closed ticket since. It belongs to F294.

**What I need from you:** one recording, about two minutes.

Close the main window entirely. Start a recording from the menu bar, let it run a moment, then stop
it. What I need to know is whether the notification actually arrived on screen — the first one
especially, because a first run evaluates the post while macOS is still showing you the permission
prompt, and that first notification is the one this whole path exists to deliver.

If you want to exercise more of it in the same two minutes: close the lid while it records. A
recording that ends because the capture died now goes through the same notification channel, so one
lid close covers both.

**One correction to what this letter used to say.** It claimed "the code work is done". That is not
true, and I should not have written it: two code-only items are still parked behind this physical
run — notification authorization at *post* time (a different bug from the ordering fix that landed),
and the alert sites that are still window-only. Neither needs you. They are on the ticket, and any
agent can take them; the run below is the only part that is genuinely yours.

---

## F353 — Press Restore Library once, on a real backup container

**Status:** `blocked`. **This letter was wrongly retired earlier today and is back.** I moved F288
to Settled on the strength of its heading ("done without you, 2026-09-17") and its `fixed` outcome,
without reading its Gaps. Its Gaps say the opposite: the case the letter named was never looked at,
and the button was never pressed. whisper-62 caught it within the hour. The residual now has its own
ticket, **F353**, which it should have had when F288 closed.

**What I need from you:** about three minutes on the restore screen.

Two things went unchecked when F288 closed:

1. **Restore Library was never actually pressed.** The apply path is covered by tests
   (`BackupRestoreApplyTests`), but on screen the confirmation was cancelled both times. So the
   screen has never been driven through to the end.
2. **The container case — the one F288's letter was written to check — was not the one tested.** An
   unrelated folder was used instead. So the case that matters is the case with no evidence.

Choose a real backup container, read the plan the screen shows you, and **accept** the confirmation
rather than cancelling. What I need to know is whether the screen told the truth about what it was
about to do — the plan it previews against what you find afterwards.

If you would rather not run a real restore, say so and this closes `wontfix` with that as the
reason; it is a reasonable answer and better than an open question nobody will ask again.

---

## F352 · F351 — Two short answers, no work either way

*(The questions were first asked as F239 and F241; those tickets closed `partial` and these are the
live tickets carrying their remainders.)*

**Status:** both were closed `partial` on 2026-09-17 with their follow-up pointing at *this file*
rather than at a ticket, which by AGENTS.md is an invalid close — so each has sat here as a question
with no board record at all. They now have tickets: **F352** (F239) and **F351** (F241).

**What I need from you:** two answers.

**1. F239 — should deleting a meeting also shred it from the index history?**

*Forget History* shipped, so you can already clear it by hand. What did not ship is doing it
automatically on delete, and that is the half that makes deletion mean deletion without you having
to remember a second command. One of: **automatic**, **opt-in**, or **leave it**. My recommendation
is opt-in. It is pure preference and there is no wrong answer — but the design depends on which you
pick, because rewriting a retained generation breaks its content-addressed name.

**2. F241 — may I download the 4-bit ASR weights (~1.2 GB), and do you have real audio?**

Only the 8-bit weights are on this Mac; the 4-bit cache entry is a 4 KB stub. The comparison cannot
run without a deliberate fetch, and a ~1.2 GB network download for a benchmark on a local-only app
is a question rather than a step. **Yes/no.** Separately: any real audio with proper nouns in it
that you do not mind being used would improve the benchmark more than the download would — the
synthetic clips give usable relative deltas and useless absolute numbers.

---

## F201 — Fifteen minutes with a microphone

**Status:** `blocked`. Dictation refinement has never been exercised with real speech in the
installed app. The numbers say it works — 75 % of attempts refine on your Mac — but what nobody has
watched is the pill and the paste.

**What I need from you:** one dictation session, about fifteen minutes.

Settings → refinement on, then hold the hotkey for each of these:

1. One short English dictation.
2. One Mandarin dictation.
3. One over 60 words — this **must skip** refinement.
4. Two back-to-back — the second should skip, busy.
5. One after five idle minutes — falling back to raw is acceptable.

Then check that the history records the raw text and the outcome for each. Tell me what looked
wrong, or say "skip" and it stays open.

---

## F230 — Watch the speaker-analysis screens once, with VoiceOver on

**Status:** `blocked`, and **narrower than when this was written**. Two of the seven checks below
are now covered by tests — cancel-mid-run leaving no `diarization.json`
(`DiarizationWiringTests.diarizationCancellationWritesNothing`) and the single-voice copy
(`DiarizationWiringTests` + `SpeakerReviewSurfaceTests`) — so they are struck. What is left is the
part no test can reach.

**What I need from you:** about twenty minutes with the app, VoiceOver on for part of it.

The fixtures exist:

```bash
Scripts/bench/diarization/make-ui-fixtures.sh audio ~/Desktop/ui-fixtures
Scripts/bench/diarization/make-ui-fixtures.sh models off   # then `on` to put it back
```

Both fixtures are synthetic speech and belong to nobody; delete the meetings afterwards.

1. **The model-absent copy**: `models off`, open the speaker-analysis screen, read the installer
   text, then `models on`.
2. **Import a fixture and leave it untranscribed** to reach the no-transcript state.
3. **VoiceOver on** (⌘F5): a transcript row for an anonymous speaker should *say* "inferred". The
   text is asserted by tests; that VoiceOver speaks it is not.
4. **Keyboard only** (Tab / arrows): every control on those screens reachable without the mouse.
5. **Dynamic Type large** and **Reduce Motion on**: nothing clipped, nothing that only animates.

The reason this is yours: spoken output, focus order and type scaling are things only a person can
confirm, and the accessibility claims are the ones that most deserve confirming rather than
asserting.

---

## F299 · F347 · F349 — Three speaker-label questions that need your own meetings

**Status:** all three `blocked`. None of them had a letter before today, which is why none has
moved. One letter rather than three, because the answers are short and this file is over its cap.

**What I need from you:** a delegation, or one command — and for the third, real time.

**1. F349 — one command, and it closes a real gap in the evidence.** The clustering threshold
(0.60) was derived on AMI: four-speaker headset audio that never over-splits. The failure that
threshold guards against — 179 clusters on a 35-minute meeting — happened on *your* mix, which AMI
structurally cannot reproduce. So the value is calibrated on material that cannot show the failure
it prevents. `sweep` prints cluster counts per threshold and needs no ground truth: run it over two
of your recordings across 0.30–1.00 and we learn where the real cliff is. Say the word and I will
give you the exact command, or do it under delegation as with the F232 probe.

**2. F347 — whether the sub-second rule helps your transcripts.** Rows under a second no longer get
a speaker name. That was decided on AMI, where 75 % of reference turns have someone else talking;
your own meetings measure 1.2–1.9 %. The trade is still positive on the closest analogue, but the
direction of the error is predicted to be adverse — a sub-second row in a quiet recording is usually
a fragment of the person already speaking, where the old label was right. Twenty of your own
sub-second rows, labelled by ear, would settle it.

**3. F299 — does the labelling actually help you find things?** The product gate nobody has scored:
a handful of find-the-moment tasks on one real meeting, timed, with labels and without. This is the
largest of the three and the least urgent — it gates promoting speaker labels out of beta, not
correctness.

*A correction on the first two:* their tickets said your meetings are something "no session here may
read". That was my wording and it overstates the rule — AGENTS.md bans reading your recordings **for
testing**, and on 2026-09-18, under your delegation, a session ran the Sortformer probe over two of
your real meetings and reported counts and timings only. These need your permission, not a wall.

---

## F428 — Copy on your iPhone, dictate on the Mac, then paste

**Status:** `blocked`. Tried once on 2026-09-24 with F425: no more "raw transcript" (that was the test
suite, F427), but the iPhone's text still did not come back. F516 rebuilt the mechanism the way Wispr
Flow, Superwhisper and VoiceInk do it — the clipboard is copied at the moment of pasting, not when
you start speaking — and it now writes the clipboard's *types* (never its content) to the log, so
one more try tells us exactly what macOS hands WhisperMeet for an iPhone item.

**What I need from you:** with the build that includes F516 installed, copy some text on your
iPhone, dictate a sentence into a text box on the Mac, wait two seconds, paste somewhere else — and
tell me what the paste gave you. I will read the log line myself.

- **Your iPhone's text** — fixed; F428 closes.
- **The dictation again** — the log will say why (for example, that the iPhone item never reached
  the Mac's clipboard before the paste, which no paste-based dictation app can work around).
- **A macOS prompt** asking whether WhisperMeet may read the clipboard — Allow keeps the restore
  working; Don't Allow turns it off and dictation still pastes.

---

## Settled — nothing needed from you

Kept as a record so nothing here is the only copy of anything; the full entries are in
[`TICKET_LOG.md`](TICKET_LOG.md).

| Was asking | Outcome |
|---|---|
| **F188** — one word about the library's schema fence | **Answered 2026-09-19: "Mark it."** Each record now carries a `schemaVersion`, written where content changes. It is a **marker, not a fence** — an already-shipped reader ignores an unknown key, so it cannot refuse on one — which is exactly why you were asked rather than told. Item 1 of F188 is done; the ticket stays open for its instance guard. |
| **F275** — confirm the capture restart on hardware, set the padding cap | **Done 2026-09-19.** Your rerun (docked, lid closed) showed the restart resuming real audio after a 0.39 s gap, then stopping and saving when macOS announced sleep. You chose that behaviour; the cap stays at 5 minutes. |
| **F257** — confirm a menu-bar-only session gets its notices | Closed `partial` 2026-09-17. The remaining ask is live under **F294** above, where it belongs. |
| **F288** — confirm the restore screen renders and reads well | Closed `fixed` 2026-09-17, but **not** fully done: its Gaps record that Restore Library was never pressed and that the container case it named was not the one tested. That residual is live above as **F353**. |
| **F244** — the fidelity benchmark's terminology review and two downloads | Closed `fixed` 2026-09-17. **Settled without you**, not by you: the term list had already been agreed with you on 09-16, and the two downloads were decided under your delegation of the same day and went ahead pinned by revision and SHA-256. Nothing is waiting. |
| **F225** — re-derive the clustering threshold on annotated audio | Closed `fixed` 2026-09-18. Answered by measurement: 18 AMI meetings, 0.60 survives as the middle of a flat optimum. |
| **F232** — Sortformer versus the shipped runtime | Closed `wontfix` 2026-09-18. Answered by measurement on two of your real meetings: stay on the current runtime. |
| **F181** — Finder / Shortcuts / Dock entry points | Closed `partial` 2026-09-18. Shipped without the Xcode-only build step; the watched folder became F318, now closed. |
