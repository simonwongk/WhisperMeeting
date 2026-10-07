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

The letters below still stand for what needs your hands (F294, F201, F230, F428, F353's check).

## Where to start

Nine entries, over the cap of five. (2026-10-07: Wave 3's sitting and questions added as #11.) (2026-10-02: F805 added — the click-through for Shrink.) (2026-09-30: F392 added — it was `blocked` with no letter, so you had never been asked; F361 folded into F201 as step 6 rather than a letter of its own.) (F355 answered 2026-09-25: the buzz is gone. F352 · F351 settled: F352 asked for a choice F295 had already shipped and you confirmed; F351 closed on your no.) Rather than drop one of your unanswered questions to get under
the line, here they are in the order I would answer them. Every one is optional and nothing rots.

| | Entry | Time | Why this order |
|---|---|---|---|
| 2 | **F294** | ~2 min | One menu-bar recording. Confirms that a windowless session's notices actually arrive. |
| 3 | **F353** | ~3 min | Press Restore Library once, on a real container. Wrongly retired earlier today — the case F288 named was never the one checked. |
| 5 | **F201** | ~15 min | A microphone and the installed app. Dictation refinement has never been watched with real speech. Step 6 (one dictation during a call) is F361's; step 7 (hold and toggle on a new build) is F731's. |
| 6 | **F230** | ~20 min | VoiceOver, keyboard and Dynamic Type on the speaker screens. Narrowed since it was written — two of its seven checks are now covered by tests. |
| 7 | **F299 · F347 · F349** | your call | Three speaker-label questions that need your own meetings. The smallest is one command. |
| 8 | **F428** | ~2 min | Copy on your iPhone, dictate on the Mac, paste — once more, with F516 installed. The log now says what macOS handed over. |
| 9 | **F392** | ~5 min, or "no" | One download you start (490 MB). Unblocks measuring Ask's search by meaning, which ships on constants nobody has measured. |
| 10 | **F805** | ~5 min | Shrink a throwaway import on the new build and check that it still plays. Shrink is the one new action that deletes audio, and no test can click it. |
| 11 | **F807 · F845 · F685** | ~45 min | Wave 3's screen checks in one sitting and one silent dictation (its four questions were answered 2026-10-07). Nothing urgent; the batch is tested headlessly and reviewed. |

---

## F294 — Confirm a menu-bar-only session gets its notices

*2026-09-26:* the lid-close recording of 2026-09-25 was done **with the main window open** (you
confirmed), so it says nothing about this question; the ask below still stands as written.

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
6. One during a phone or FaceTime call. The call puts the built-in microphone in its voice mode,
   which is what crashed the app twice in September (F356). It should transcribe correctly — that
   is **F361**, and it is the only part of it a test cannot do. Say "skip 6" if you would rather not.
7. Once a build from 2026-10-01 or later is installed (`Scripts/install-app.sh`; it includes F403 and
   F404, which changed how a dictation starts the microphone): one dictation in hold mode and one in
   toggle mode. Both should start listening and transcribe as before. That is **F731**: no test can
   press a real microphone, so this is the only check of the new start path.

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

*2026-09-26:* you tried it (five dictations, 12:05–12:07) and I read the log: at every paste the
Mac's clipboard held **zero items** — the iPhone's copy never reached the Mac at all, so there was
nothing for the restore to give back, and it put the empty clipboard back over the dictation. That
is why nothing pastes afterwards. It does not yet say whether Universal Clipboard itself is down on
this Mac or whether the item needs a read this code does not do.

*Same day, later:* you tried the plain paste into Notes — **nothing**. So it is not WhisperMeet.
From the Mac side (settings and system log only): Handoff is on, Bluetooth and Wi‑Fi are on, the Mac
sees your iPhone and advertises its own clipboard to it, but the file macOS uses for the *incoming*
clipboard was last written **2026-09-21 21:55** — the last time an iPhone copy reached this Mac,
three days before the F516 build existed.

**What I need from you (on the iPhone, in this order, then one paste test after each):**
1. 设置 ▸ 通用 ▸ 隔空播放与接力（或"隔空播放与连续互通"）▸ **接力** — 关掉，再打开。
2. 控制中心里确认 **Wi‑Fi 是开着的**（用蜂窝数据也要开着 Wi‑Fi；通用剪贴板走的是点对点 Wi‑Fi）。蓝牙关一次再开。
3. 设置 ▸ 最上方你的名字 — 和 Mac 是同一个 Apple ID，且已开双重认证。
4. 都还不行：iPhone 重启一次；再不行，Mac 上 系统设置 ▸ 通用 ▸ 隔空投送与接力 ▸ 接力 关再开。
Once a plain paste works again, do the dictation step once and I read the log line myself.

*Earlier one-step ask:* copy some text on your iPhone, then paste it straight into any app on the
Mac — Notes, say — without dictating in between.

- **Nothing pastes** — Universal Clipboard is not reaching this Mac right now; WhisperMeet is not
  in the path. The usual causes: 系统设置 ▸ 通用 ▸ 隔空投送与接力 ▸ "允许在这台 Mac 和 iCloud 设备之间使用接力"
  off on either device, different Apple IDs, Bluetooth or Wi‑Fi off, or the two devices not both
  awake and near; toggling Bluetooth off and on on both usually brings it back. Once a plain
  paste works, do the dictation step once more and I read the log again.
- **The iPhone's text pastes** — then do: copy on iPhone → dictate into a text box → wait two
  seconds → paste elsewhere, and tell me what came out. The log will now say whether the Mac saw
  the iPhone item (`1 item(s): …is-remote-clipboard…`) or, as today, nothing.

*Earlier ask, for the record:* with the build that includes F516 installed, copy some text on your
iPhone, dictate a sentence into a text box on the Mac, wait two seconds, paste somewhere else — and
tell me what the paste gave you. I will read the log line myself.

- **Your iPhone's text** — fixed; F428 closes.
- **The dictation again** — the log will say why (for example, that the iPhone item never reached
  the Mac's clipboard before the paste, which no paste-based dictation app can work around).
- **A macOS prompt** asking whether WhisperMeet may read the clipboard — Allow keeps the restore
  working; Don't Allow turns it off and dictation still pastes.

---

## F392 — Add search by meaning, or tell me not to

**Status:** `blocked`. Ask Meetings can also search by meaning, using an on-device model
(`intfloat/multilingual-e5-small`, about 490 MB). Two constants decide what it returns, and neither
has ever been measured: the similarity floor (0.70) and the rank-fusion constant (60). The set of
test questions to measure them against is committed; the model is not installed on this Mac. Putting
it there is a download into WhisperMeet's own runtime, and it also switches Ask to searching by
meaning for you, so it is your action to start, not a test's. That is why no agent has done it.

**What I need from you:** in the sidebar, open **Ask Meetings** and press **Add Search by Meaning
(490 MB)** — or tell me "no", and F392 stays parked with nothing lost.

The download comes once from Hugging Face. After that, searching runs on this Mac and nothing about
your meetings is uploaded (the button's own help text says the same). Once it is installed, an agent
runs the measurement against the committed questions only, never your meetings, in a few minutes.
The same run gives F396 the per-language numbers it is waiting for.

---

## F805 — Shrink a throwaway meeting once, on the new build

**Status:** `blocked`. The build installed on 2026-10-02 shows each meeting's disk use and adds **Shrink…**. Shrink
replaces a meeting's audio with one compressed file of about 15 MB an hour, and deletes the original permanently.
Tests cover the steps and their order, but the target cannot click its own buttons, so the screens have never been
used.

**What I need from you:** about five minutes, on a meeting you don't need. Never use a real one: Shrink cannot be
undone.

1. **Import a throwaway file:** a copy of any voice memo, or a 30-second recording you make for this. Let it transcribe.
2. **On its page:** the header should show a size such as "1.2 MB" next to the date and length. Press **Shrink…**. The
   dialog should give the size before and after, and say the original is deleted permanently. Press **Shrink**.
3. **Afterwards:** it should report "Shrunk … from … to …". It should still **play**, and **Transcribe Again** should
   still work.
4. **Settings → Meeting library → Show Storage…:** meetings should be listed largest first, with a total. A meeting that
   can't be shrunk should say why under its title.

Tell me what looked wrong, or "fine". One more choice is yours: 32 kbps is kept, and 24 kbps scored the same on the
test clips while saving about 4 MB more an hour. Say "24" if you want the smaller one.

---

## F807 · F845 · F685 — Wave 3: one sitting at the screen, and four questions

**Status:** `blocked` (F807, F845, F685, F682). The 2026-09-28 → 10-07 batch fixed about 70 tickets in recording, quit, menu
bar, dictation paste and privacy, hotkeys, installers, backups, history and vocabulary. Each was tested headlessly and
reviewed by a second agent; what only a person can see is collected here. Install the batch's build first (I will tell you
when it is installed). Use bench clips or throwaway imports, never a real meeting.

**What I need from you:** one sitting of about 45 minutes (split it as you like).

1. **Quitting and the menu bar (F529, F672, F673, F543, F528, F674) — ~10 min.** Start a recording, talk for 20 s, press ⌘Q:
   "Stop and save the recording before quitting?" should appear; choose Keep Recording, then ⌘Q again and Stop & Quit.
   Relaunch: the meeting is saved and ready to transcribe, not "interrupted". Also try ⌘Q while "Finishing…" shows. With
   the window closed, the menu-bar icon shows a recording; ⌘/ opens Keyboard Shortcuts.
2. **Two windows (F564, F675) — ~3 min.** ⌘N for a second window on the same meeting; rename in one, close the other: the
   name stays. Type notes in both: nothing is lost.
3. **Settings (F565, F520, F567) — ~5 min.** The screen-recording row has **Allow…**. Start any model install and press its
   **Cancel**: it says it was cancelled and the old version still works.
4. **Dictation (F521, F523, F537, F585, F586, F600, F601, F656) — ~15 min.** Settings ▸ Quick Dictation ▸ Change: Esc cancels,
   Tab/Space are refused. Dictate into a password field: the pill says "Not pasted — secure input" with **Copy**, and nothing
   is on the clipboard until you press it. Dictate into Terminal, iTerm2 or Ghostty if you use them (F682 needs the log line
   each one writes). Turn VoiceOver on (⌘F5) and dictate once: the outcome is spoken once.
5. **One silent press (F845) — 1 min.** In a quiet room, press the dictation key and say nothing: nothing should be pasted.
   This checks the new −60 dBFS floor against your real microphone.
6. **Second Opinion, links, vocabulary, Ask (F605, F661, F539, F602, F536, F455, F842) — ~10 min.** A refused Replace shows
   its alert over the sheet. Add from a Link with a bad URL shows the error inside the sheet. Correct Toward Vocabulary
   shows a progress bar and Cancel. Edit a transcript, then Ask about the removed words: they are not found. Export SRT:
   cue times keep their milliseconds.
7. **Optional, with care (F685):** only if you want an F-key as your dictation trigger (yours is Right ⌘, which this does not
   affect). Steps and the mouse-only escape are in F685.

**Four questions — answered 2026-10-07:** replacement rules will also apply to Quick Dictation (F821); a deleted meeting's
copy in the restore safety folders is wiped after its week (F664); the "two versions" screen gets a "Keep the version on disk"
button (F833); and both quit choices stay as they are — logout asks first, Stop & Quit leaves the meeting ready to transcribe
(F529, F673). The three changes are on the board for the next batch.

---

## Settled — nothing needed from you

**F464 — answered 2026-09-26: "改" (yes).** The spec sentence is amended in the same commit as the
fix: the meeting index alone locks the whole library; a damaged vocabulary or replacement-rules file
makes only that list read-only. The letter as it stood is kept below for the record.

### The F464 letter, as asked

**Status (when written):** `blocked` on one sentence of [`PRODUCT_SPEC.md`](PRODUCT_SPEC.md). The fix is written,
reviewed and tested on a branch (`8194f33`, 605 lines, 9 files); it is not merged because it
contradicts the spec as it stands, and the spec is yours, not mine.

Today, if `vocabulary.json` or `replacement-rules.json` is damaged — a hand edit, a half-written
file — the app opens the *whole* library read-only: no recording, no import, no transcription, no
meeting edits, and the only recovery offered (retained meeting-index generations) cannot clear it,
because the damage is not in the meeting index. The spec says exactly that: *"When any index copy
is damaged, open the library read-only and block every mutation, including recording, import and
transcription."*

The fix makes the damage local: the broken list is quarantined (never overwritten), *that list* is
read-only, its own notice offers to keep the loaded copy or start a new list — and recording,
import, transcription and meeting edits carry on. The meeting index keeps today's rule unchanged.

**What I need from you:** say **yes** or **no** to changing that sentence to: *"When the meeting
index cannot be fully read, open the library read-only and block every mutation, including
recording, import and transcription. A damaged vocabulary or replacement-rules file is quarantined
and makes only that list read-only: recording, import, transcription and meeting edits continue,
and the list's own notice offers to keep the loaded copy or start a new list."* (The same paragraph
also still says the app "does not offer an in-app recovery action", which has been false since
Settings ▸ Recover Library… shipped; I would correct that at the same time.)

- **Yes** — I merge the branch, amend the spec in the same commit, and F464 closes.
- **No** — the branch is kept for the record, F464 closes `wontfix`, and the whole-library lock stays
  as the spec intends.

I recommend yes: a typo in a word list should not stop a lecture from being recorded.

---


- **F352 · F351 (2026-09-25).** F352 asked whether deleting a meeting should also remove its text from
  the index history: automatic removal one week after the delete had already shipped as F295 on
  2026-09-17, and you confirmed keeping it on 2026-09-24. Closed invalid. F351 asked whether to
  download 1.2 GB of 4-bit weights for a benchmark: you said no; closed won't-fix.

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
