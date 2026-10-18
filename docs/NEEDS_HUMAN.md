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

**Rebuilt 2026-10-17 (whisper-27), from your answers in chat.** Twelve letters had piled up, about 4½ hours of checks. You
chose a short list, so there is now **one** letter, about 30 minutes. The other sittings, and the tests you skipped or have no
equipment for, are closed in `TICKET_LOG.md` as "checked by code only"; one line each is under Settled. The old letters' full
text is in this file's git history. (2026-10-18, whisper-dfd4: Wave 8 added one optional second entry, two recordings.)

| | Entry | Time |
|---|---|---|
| 1 | **The short list** (F392 · F805 · F353 · F294 · F201) | ~30 min |
| 2 | **Two recordings, optional** (F737 · F1042 · F727) | a few minutes, plus one long meeting |

---

## F392 · F805 · F353 · F294 · F201 — The short list: five checks, about 30 minutes

**Status:** `blocked` (F392, F841, F805, F353, F294, F201, F731, F845, F428, F682). Agents can't see your screen, speak into
your microphone or click your buttons, so these are the checks only you can do. Do them in any order, whenever it suits you,
and tell me what looked wrong, or just "fine". Say "skip" for any step you'd rather not do.

**What I need from you:** about 30 minutes for the five checks below.

**Set up 2026-10-17 (whisper-27).** Everything is in the Desktop folder **WhisperMeet short list**: start with
`Checklist.txt`, which is these five steps in plain words. The folder also holds the test clip for step 2, a double-click
launcher for step 3's test copy, and a double-click cleanup for when you're done.

1. **Turn on search by meaning (F392) — 5 min.** In the sidebar, open **Ask Meetings** and press **Add Search by Meaning
   (490 MB)**. Tell me when it has finished. It downloads once; after that, searching stays on this Mac. An agent then measures
   how well it works using test questions only, never your meetings.

2. **Shrink a throwaway meeting (F805) — 5 min. Never use a real meeting.**
   - Drag **Test clip - safe to delete.wav** (in the Desktop folder; synthetic speech) into WhisperMeet and let it
     transcribe. Delete that test meeting when you're done.
   - On its page, the header shows a size such as "1.2 MB". Press **Shrink…** and read the dialog: it should show the size
     before and after. Press **Shrink**.
   - Afterwards it should say "Shrunk … from … to …". The meeting should still **play**, and **Transcribe Again…** should
     still work.
   - Settings → Meeting library → **Show Storage…**: meetings are listed largest first, with a total.
   - Once a build with F1040 is installed, the original goes to the Trash instead of being deleted: check that it is there.

3. **Restore a backup once (F353) — 5 min, in a test copy of the app, so your real library is never restored over.**
   - Double-click **Step 3 - open the test copy.command** in the Desktop folder. A second WhisperMeet window opens on a small
     test library with two sample meetings (one has no audio on purpose).
   - In that test window: Settings → Meeting library → **Back up library…**, into the folder's **Test backups**.
   - Then press **Restore…** and choose *the backup you just made*.
   - Read what the screen says it will do, then press **Restore**. Don't cancel: pressing it is the part nobody has tried.
   - Tell me whether what it said matches what happened. The test library should look the same afterwards. Then quit the test
     copy.

4. **A recording with no window open (F294) — 2 min.** Close the main window completely. Start a recording from the
   **menu-bar icon**, wait a few seconds, then stop it from the menu bar. Did a notification appear on screen? The first one
   matters most.

5. **A dictation session (F201, F731, F845, F428, F682) — 15 min.** In Settings, turn on **Refine with local AI (grammar
   cleanup)**. Then:
   - Dictate one short English sentence, and one in Mandarin.
   - Dictate something over 60 words. It should paste without being polished.
   - Dictate twice quickly, back to back.
   - Set **Trigger mode** to **Hold to talk** and dictate once; then to **Toggle on/off** and dictate once. Both should work.
     Put it back the way you like it afterwards.
   - In a quiet room, press the key and say nothing. Nothing should be pasted.
   - Copy some text on your iPhone, dictate one sentence on the Mac, wait two seconds, then paste somewhere else. Did you get
     the iPhone's text back?
   - Dictate once into the terminal app you use.

   Tell me anything that looked wrong. I read the app's own log for the rest (never your transcript text).

---

## F737 · F1042 · F727 — Two recordings, optional (added 2026-10-18 by whisper-dfd4, Wave 8)

**Status:** `blocked` (F737, F1042, F727). Wave 8 changed how a recording keeps its two tracks in time, and logs how long Stop
takes. No test can make a real recording, so two recordings on the next installed build would show whether that holds. Both
are optional; say "skip" and they close as checked by code only, like the other skipped sittings.

**What I need from you:** after the Wave 8 install, make the two recordings below when convenient and tell me they're done.
I read only the app's own log lines and the recordings' timing counts, never what was said.

1. **A short recording with one sleep (F737).** Record for a minute, close the lid or choose Apple menu ▸ Sleep, wake the Mac,
   record another minute, then press Stop. Tell me whether WhisperMeet showed any error, and whether a crash report appeared.
2. **One long meeting with the Mac kept awake (F1042).** Any real meeting of 2–3 hours, ideally with a USB or Bluetooth
   microphone, and no sleep during it. Nothing else to do; I read the drift counts Stop writes to the log.
3. **F727 — skip unless curious.** A throwaway probe in `.claude/wave8/F727-probe/` would show whether building a capture
   stream raises a Screen Recording prompt. It is low priority.

---

## Settled — nothing needed from you

**Closed 2026-10-17, from your answers in chat — checked by code only.** You chose the short list above, so these were closed
in `TICKET_LOG.md`: the Wave 3 to Wave 7 sittings (F807, F889, F904, F981, F1010), the speaker screens' VoiceOver check (F230),
F174's visual checks, and a dictation during a call (F361). You skipped switching off Accessibility while the app runs (F685).
You have no network drive (F1031, F1035) and no older M1 or M2 Mac (F760), and you don't use an F-key trigger (F861). The two
Wave 5 design questions were answered instead: a short menu-bar error line (F924), and a confirmation when ⌘ or ⌃ alone is
chosen as the dictation key (F925). If something looks wrong in use, tell any session and it becomes a new ticket.


**F299 · F347 · F349 — answered 2026-10-12, in chat.** F349: "Yes, counts only" — a session runs the cluster-count sweep over two of
your meetings, read-only, printing counts per setting and never any words — done the same day: both meetings hold 3 speakers from 0.50
to 0.90, so the shipped 0.60 is inside a stable range (curve in `DIARIZATION_SCORECARD.md`; F349 closed). F347 and F299: "Drop both for now" — short
rows stay unnamed and speaker labels stay in beta; the speaker-analysis spec's value gate and the scorecard's Value row now say the gate was
dropped (both closed; reopen either any time). The letter as it stood is kept below.

### The F299 · F347 · F349 letter, as asked


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

**F891 — answered 2026-10-09: "no".** None of the apps I could see were running at the morning's
slow minutes, and the first slow dictation on the new build (2026-10-08 19:40, 4.0 s → 6.93 s)
showed the GPU 28 % busy, so it was never the GPU. Measured instead: after minutes idle, the
recognizer's first request takes 0.7 s (your worst case 6.9 s, from disk) and the resident
refiner's 2.3 s against its 1.4 s budget — the system pages their weights out between dictations
on an 18 GB Mac with 9–10 GB of swap in use. The fix (F891, same commit): a press-down wakes both
resident models, so that page-in happens while you speak. The letter as it stood is kept below.

### The F891 letter, as asked

#### F891 — What was using the GPU while you dictated at 11:27 and 12:05–12:11 today?

You said dictation has been getting slower. It has, and I can say exactly how much: the app's own
log for 2026-10-08 shows your 3–5 s clips coming back in **5.3, 3.1, 9.3 and 10.4 s**, while
other clips the same day — longer ones — came back in under a second (0.37 s for 3.3 s of speech,
0.87 s for 15.6 s). The model is not slow; something was in its way.

I drove the installed recognizer and refiner exactly as the app does
(`Scripts/bench/dictation-latency.py`, new) under every condition I could think of: the refiner's
4.3 GB load, its kill-and-reload cycle, 9 GB of memory pressure with 2.5 GB of the recognizer
reported swapped, twelve CPU hogs, a hundred requests in a row, silence, noise, clicks, −30 dB
speech, repeats. Every one stayed at 0.3–0.8 s. **One thing reproduced it: another process on the
GPU.** With a second MLX process running, the same clip took 4.2–4.8 s. That is the shape of your
slow dictations, and it is the one resource the app cannot reserve.

What I could not find out from records is **what** was on the GPU at those minutes. It was not a
test suite (the Wave 4 agents' first run today was 12:14), not a summary or transcription in the
app (its index was last written yesterday), not disk or Time Machine. The remaining candidates are
things only you would know: a video or voice call with camera effects, a screen share, a video
playing, a game, another AI tool running a local model, or Chrome with a heavy page.

Two things are in place so the next slow one explains itself:

- The build on this branch reads the GPU's busy share just before recognition and writes it into
  the same log line: `qwen3-asr-1.7b-8bit transcribed in 5.28s (GPU 92% busy before the request)`.
  Above 75 % it also skips the polishing pass, which could only have added its full 0.8–1.5 s
  budget and then been killed and reloaded — so a slow dictation under a busy GPU is now up to
  1.5 s shorter and the refiner stays resident for the next one.
- That build is installed and running since 14:00 on 2026-10-08 (the app was idle; quit, installed,
  relaunched; its log shows "dictation enabled (hotkey 54 mode hold)" with no tap error). The
  tagged timing trace I had put in the installed Qwen helper while measuring was removed by the
  launch sync, which copies the shipped helper back; the backup copy is deleted too.

**What I need from you:** tell me what was open or running at 11:27 and 12:05–12:11 today (a
call? a video? another local model?), or just dictate a few times with the new build installed and
send me the "transcribed in … (GPU …% busy …)" lines from `/usr/bin/log show --predicate
'subsystem == "com.whispermeet.app"' --last 1d`. If it turns out to be something the app owns, that
is F891's fix; if it is another app, the fix is knowing which one.

*Status: open question. F891 is `blocked` on the board pointing here; F890 (the measurement, the
log line and the refiner skip) is closed with the evidence.*

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
