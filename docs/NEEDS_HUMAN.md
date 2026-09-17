# Needs human

The queue of tickets blocked on a physical action or a decision only the user can make — each with a
**What I need from you:** line. How an entry arrives here, and the cap on this file, are governed by
the ticket rules in [`../AGENTS.md`](../AGENTS.md); open work stays in [`TICKETS.md`](TICKETS.md).

---

## F275 — Confirm the capture restart on the hardware, and set the padding cap

**Status:** the code is shipped and tested; these two things cannot be settled without you.

**What I need from you:** two physical runs and one number.

**The runs.** The restart decision is pinned by tests, but no test can prove that rebuilding an
`SCStream` after a display disappears actually resumes audio on a real Mac — that depends on
ScreenCaptureKit's behaviour, not on this code.

1. **Docked, lid closed.** Start a recording with an external display connected, close the lid, keep
   talking for a minute, reopen. Expected: recording continues, and a banner says it resumed after a
   display was disconnected with the gap marked as silence. This is the case that lost you 63
   minutes of a meeting, so it is the one worth doing first.
2. **Undocked, lid closed.** Same, but with no external display, so the Mac actually sleeps. Expected:
   the recording is finalized and saved, and the banner says so rather than the app silently showing
   a recording that is no longer running.

If you can, note the `SCStream` error each time — `log show --last 10m --predicate 'subsystem ==
"com.whispermeet.app"' | grep -i restart` will show what the app logged.

**The number: how long a gap may be padded before the meeting is split instead.** Default shipped:
**5 minutes**. Padding a gap writes real silence into the audio so that timestamps after it still
line up with the clock; the trade is disk, at **384 KB per second** of silence across the two raw
tracks:

| Gap padded | Disk it costs | Reasonable? |
|---|---|---|
| 1 min | 23 MB | clearly fine |
| 5 min (current default) | 115 MB | a coffee break, still one meeting |
| 30 min | 690 MB | a long lunch — probably two meetings |
| 8 h (lid shut overnight) | 11 GB | clearly not |

Being wrong either way is harmless: too low and you get two meetings instead of one, too high and
you get more silence. Nothing about the timeline breaks at any value. Say a number and I will change
the default; leave it and 5 minutes stands.

## F230 — Watch the speaker-analysis screens once, with VoiceOver on

**Status:** the fixtures exist and the code-side claims are tested. What is left cannot be observed
by a test.

**What I need from you:** twenty minutes with the app, VoiceOver on for part of it.

The three blockers F229 hit are gone — `Scripts/bench/diarization/make-ui-fixtures.sh` generates
what was missing:

```bash
Scripts/bench/diarization/make-ui-fixtures.sh audio ~/Desktop/ui-fixtures
Scripts/bench/diarization/make-ui-fixtures.sh models off   # then `on` to put it back
```

`ui-single-voice.wav` produces exactly one cluster, so the single-voice state is reachable.
`ui-long-cancel.wav` is three hours that analyse in 59 s, which is a wide enough window to press
Cancel — the 46-minute real meeting finished in ~15 s, which is what defeated the last attempt.
Both are synthetic speech and belong to nobody; delete the meetings afterwards.

What to look at:

1. **Cancel mid-run**, using the long fixture. Afterwards there should be no `diarization.json` in
   the meeting's folder.
2. **The single-voice copy**, using the single-voice fixture. It should not say "one voice" in a way
   that implies the others were identified — that distinction is deliberate.
3. **The model-absent copy**: `models off`, open the speaker-analysis screen, read the installer
   text, then `models on`.
4. **Import a fixture and leave it untranscribed** to reach the no-transcript state.
5. **VoiceOver on** (⌘F5): a transcript row for an anonymous speaker should *say* "inferred". The
   text is asserted by tests; that VoiceOver actually speaks it is not.
6. **Keyboard only** (Tab / arrows): every control on those screens reachable without the mouse.
7. **Dynamic Type large** and **Reduce Motion on**: nothing clipped, nothing that only animates.

Snapshot `meetings.json` before and after if you want to be careful — nothing here should change it
beyond the meetings you import and delete.

The reason this is yours: VoiceOver's spoken output, keyboard focus order and type scaling are
things only a person can confirm, and the accessibility claims are the ones that most deserve
confirming rather than asserting.

---

## F241 — Two decisions about the ASR benchmark

**Status:** the long-form fixture is shipped and it reaches the batched meeting path. These two are
the half I could not do.

**What I need from you:** a yes/no on a download, and some real audio if you have it.

**1. May I download the 4-bit Qwen weights (~1.2 GB)?** The benchmark's whole problem is that it
cannot tell a good model from a bad one: when 4-bit weights were rejected, the bench had scored them
*perfectly* — 0.0000 error on all ten clips, identical to the 8-bit weights it kept. Meanwhile on a
real recording the 4-bit model turned "Apple Times" into "EPT" and "Hadas" into "Head Office".

The new long-form fixture does score non-zero (3.09%), so it finally has a scale. But I cannot check
whether it actually separates the two models, because only the 8-bit weights are on this Mac — the
4-bit entry in the cache is a 4 KB stub. It is a normal Hugging Face download, but it is a network
fetch for a benchmark, on a machine whose whole point is staying local, so I would rather ask.

**2. Do you have a recording with names and product terms in it?** This matters more than the
download. The fixture's errors turn out to be mostly *spacing* around English words inside Chinese
sentences — real, but not the kind of mistake that made 4-bit unusable. The mistakes that mattered
were proper nouns, and the synthetic bench clips do not contain any.

Any meeting where people say company names, product names or colleagues' names would work, and it
would not need to be shared — I would only need the audio on this Mac and a rough transcript to
score against. Without it, the bench can tell that a model is *different*; it still cannot tell that
one is *wrong about names*, which is the failure you would actually notice.

---

## F257 — Confirm a menu-bar-only session now gets its notices

**Status:** the code is shipped and tested; this needs the app in front of you.

**What I need from you:** one run, about two minutes.

Everything about the app's lifecycle used to hang off the main window, so recording from the menu bar
with the window closed meant no notice when something went wrong and no final save on quit. That is
fixed, but no test can watch a windowless launch — the delegate firing without a window is AppKit's
promise, not this code's.

1. **Close the main window** (⌘W). The menu-bar icon stays; the app is still running.
2. **Start a recording from the menu bar**, say a few words, then **Stop & Transcribe** from the same
   menu.
3. **Quit from the menu bar** while a transcript edit is still fresh — type in a transcript, then
   quit within a second or two. Reopen and confirm the edit survived.
4. If you can make a save fail (the simplest way: with WhisperMeet quit, `chmod 500` the library
   folder, then launch and add a tag), confirm you get a **notification** saying changes could not be
   saved rather than nothing at all. Put the permissions back with `chmod 700` afterwards.

Expected: a notification for anything that would have been an alert, and no lost edit on quit. If a
notification never appears, check that WhisperMeet is allowed to notify in System Settings →
Notifications — the app asks the first time it needs to, which may be during this test.

What is still window-only, deliberately: the live recording-health banner. Telling you about a
degrading recording while you have no window open needs the menu itself to carry it, which is a
design question rather than a fix. Say if you want that.

---

## F239 — Should deleting a meeting also shred it from the saved index history?

**Status:** the *Forget History* command is shipped (Settings → Meeting library). This is the
remaining half, and it is a defaults question rather than an engineering one.

**What I need from you:** one decision — automatic, opt-in, or leave it.

**The situation.** WhisperMeet keeps recent copies of your meeting index so a bad save can be undone
(that is what recovered your library once already). Those copies contain meeting titles, transcripts
and notes. When you delete a meeting, its recording goes immediately — but its text stays in those
copies until they age out, which is about a week, **except** for the copy holding the most meetings,
which is kept indefinitely. On a library that is not growing, that copy can hold a deleted meeting's
transcript for as long as you keep using the app.

You can now clear all of it at once with *Forget History*. The question is whether deleting a single
meeting should shred just that meeting from those copies, automatically.

| Option | What you get | What it costs |
|---|---|---|
| **Automatic** | Delete means delete, with nothing to remember | Each deletion rewrites the saved copies, so the undo protection for *that moment* is weakened — and the rewrite is the most intricate part of the storage code |
| **Opt-in** (a setting, default off) | The same, for anyone who turns it on | Anyone who does not know the setting exists is where we are today |
| **Leave it** | *Forget History* covers the need, bluntly | You have to remember to run it, and it clears everything rather than one meeting |

My recommendation is **opt-in**, for one reason: automatic would silently weaken the protection that
exists because this library was destroyed once, and that trade should be yours to make knowingly
rather than a side effect of pressing Delete. But if you delete sensitive meetings regularly,
automatic is the only option that does not depend on memory.

---

F243 was decided by the user on 2026-09-16 and moved to `TICKETS.md`: a silence gate may drop a
chunk only when it is COMPLETELY silent. The broader near-silent gate the estimate was based on
was not authorised.

---

## F288 — Confirm the restore screen renders and reads well

**Status:** the whole backup-restore mechanism is shipped and tested — plan, verification, apply,
rollback, folder rebuild. This is the one part no test in this repo can reach.

**What I need from you:** one look at Settings → Library, a couple of minutes.

The `WhisperMeet` target has no UI test harness (F174's standing reason), so every string, the plan,
the apply and the rollback are unit-tested and *that the button exists on screen* is not. Three
things to check by eye:

1. **"Restore…" appears** beside "Back up library…", and the caption beneath the backup description
   reads sensibly next to it.
2. **Choosing a dated folder** inside `WhisperMeet Backups` brings up the confirmation, and its text
   is readable. It should lead with how many files are in your library but *not* in that backup,
   then the replace/restore counts, then that your current library is copied aside and kept.
3. **Choosing something that is not a backup generation** — the `WhisperMeet Backups` folder itself,
   or any unrelated folder — gives a sensible refusal rather than an odd-looking empty plan.

**It is safe to try, and that is asserted rather than promised.** Requesting a restore writes
nothing: a test compares both the library and the backup byte-for-byte before and after a plan is
built, including under the slow deep check. Open the confirmation and cancel it as often as you
like. To exercise it on synthetic data instead of your own library,
`Scripts/rehearse-recovery.sh` builds a damaged library in a temp directory and touches nothing of
yours.

If you would rather not, F191 stays `partial` with the mechanism tested and the screen unconfirmed.
Nothing else depends on it.

---

## F244 — The fidelity benchmark is built and waiting on two things only you can give

**What I need:** your terminology review, and a yes or no on two downloads. Roughly 30 minutes of
reading; the runs afterwards are unattended.

Everything else is done. `run_fidelity.py` drives the app's own helper scripts over a corpus,
`report.py` turns the records into a scorecard and a review page that lists only the flagged items,
and a Swift test keeps the bench's copy of your prompts byte-equal to the ones the app sends. A
`--smoke` run against the Qwen already installed on this Mac takes 39 seconds and passes.

### 1. The corpus terminology (`Scripts/bench/fidelity/corpus/APPENDIX.md`, local-only)

The eight topics and the protected-term list. I drafted them; you know whether the terms are the
right ones, whether the aliases are the forms that actually appear in your work, and whether a topic
is missing. Nothing can be measured until this is right, because the protected terms *are* the
measurement — and they also seed F245's guard list, so a term missing here is a term the app will
never learn to protect.

One request while you are in there: the claims now take `action_aliases` and `target_aliases`, which
say what counts as the same claim said differently. These must be written **before** any model runs.
Written afterwards they become a per-item choice about which paraphrases to forgive, and since the
sensitive-versus-control difference decides whether we replace the model, that choice could
manufacture the difference it claims to measure.

### 2. May I download two models?

Gemma 4 E4B and Breeze2, into `~/Library/Caches/WhisperMeet-Bench/` — not the checkout, which is
under `~/Documents` and may be iCloud-synced. Pinned revisions behind a SHA-256 gate, the same way
the app's own installer works. Without them the benchmark can say whether Qwen has a problem but not
whether switching would fix it, which is the question F246 has to answer.

This is separate from the two 4-bit ASR weights in the F241 entry above; answering one does not
answer the other.

### What the smoke run already found, on six deliberately mundane items

Not the real measurement — six neutral items, one sample each, no sensitive arm and no control, so
the scorecard prints *incomparable* and refuses to imply a difference. But three of them are worth
your attention now, because they are not about politics at all:

- **A Traditional-Chinese dictation line came back Simplified, and the app would paste it.** 個→个,
  貨→货, 倫→伦, 辦→办. The refinement prompt says "Mandarin Chinese" and never names a script, and
  the app's language check reports "Chinese" for both scripts, so it cannot see the conversion.

  I did not leave that as an inference. `Tests/WhisperCoreTests/RefinementGuardVectorTests.swift`
  runs the app's real output guard over that exact pair and records the verdict: **accepted**. So
  if you dictate in Traditional Chinese, this is happening to you now — not "might be". Recorded on
  F245, which owns the prompt.

  **This one no longer needs your corpus review.** Naming the script in the prompt, and adding a
  Traditional/Simplified check to the guard, are justified by the measurement already taken on
  neutral business text. If you want to green-light one thing from this entry, it is this — it is
  the cheapest item on the list and the only one already demonstrated to affect your own writing.
  The corpus is still needed for everything about politically sensitive material, which is a
  separate question.
- **Asked to fix one misspelling, the model also rewrote 陳經理 into 陳怡君** — a title into a
  person's name. That is not a recognition error, it changes who the transcript says was speaking,
  and the correction sheet arrives with every proposal pre-selected, so it lands on one click.
- **An English summary dropped the approver's name entirely** and attached the person responsible
  for the problem to the fix rather than the act. Ordinary business text.

Each is one observation, so none is a rate. They tell you the harness can see this class of thing,
and that the class is not hypothetical.

### If you would rather not

The harness keeps working on the neutral corpus, so nothing rots. F244 simply stays blocked, and
F245 and F246 stay blocked behind it — meaning the app keeps shipping the current prompts and the
current guards, and the script drift above stays unfixed. That is the cost of leaving it, stated so
it is a choice rather than a default.
