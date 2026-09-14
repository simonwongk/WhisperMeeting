# Prompt: verify the speaker-analysis UI in the installed app

Paste everything below the line into an agent that has **Accessibility permission** (System Settings →
Privacy & Security → Accessibility) so it can click and type. Written 2026-09-13, against commit
`fe0a62a`.

---

You are verifying a feature in **WhisperMeet**, a native macOS app, already installed at
`/Applications/WhisperMeet.app`. The repository is `/Users/simonwang/Documents/Whisper`.

The feature is **speaker analysis**: a post-meeting, entirely local pass that labels parts of a
finished transcript with anonymous labels like "Speaker 1". It has been built and unit-tested, and
its output has been verified on real audio. What has **never** been checked is the actual interface —
nobody has clicked the buttons or heard VoiceOver read a label.

## Before you touch anything

This project destroyed a user's meeting library once before, so these are hard rules:

1. **Never run `.build/WhisperMeet.app`.** Only `/Applications/WhisperMeet.app`. Two bundles at
   different commits can hold incompatible library schemas — that is what caused the incident.
2. **Snapshot the index first** and re-check it after every destructive-looking step:
   ```bash
   LIB="$HOME/Library/Application Support/WhisperMeet"
   mkdir -p /tmp/wm-snap && cp "$LIB"/*.json /tmp/wm-snap/
   shasum -a 256 "$LIB/meetings.json"
   ```
   It should read `26e8ba17323de02e…` and must not change except where a step legitimately edits a
   meeting. If it changes unexpectedly, **stop and report**.
3. **Do not delete a meeting, cancel a recording, or start a recording.** Those are destructive by
   design.
4. **Never paste transcript content into your report.** Timestamps, labels, button text and counts
   are fine. The transcripts are the user's real meetings.
5. If the installer needs re-running: quit the app first, it refuses while the app is open.

## What to drive

Use the meeting **"Meeting Aug 20, 2026 at 17:32"** (tagged `epoch-shop`, 46 min, 627 transcript
rows). It has already been analysed successfully in a headless probe and produced 4 speakers with
385 of 627 rows labelled, so you have a known-good baseline: if the UI shows something different,
that difference is the finding.

Screenshot after every step and **look at each screenshot** — a blank or unchanged frame means the
click missed, not that the step passed.

### 1. Entry point
Select the meeting, scroll to the transcript, open the **Improve** menu (sparkles icon, between the
Read/Edit picker and Copy). Confirm **"Analyze Speaker Turns…"** is present and enabled.
- Open the same menu on a meeting that is still transcribing, or has no transcript. The item must be
  absent or disabled, **with a plain-language footnote in the menu saying why** — a greyed row with
  no explanation is a finding.

### 2. Disclosure
Click it. A confirmation should appear stating that analysis runs on this Mac, that nothing is
uploaded, that labels are anonymous guesses, and — explicitly — that **voices which sound alike are
sometimes merged into one label**. Verify that sentence is actually present; it is a measured
weakness of the runtime, not boilerplate.
- Click **Cancel**. Confirm nothing ran and no labels appeared.

### 3. Run it
Click through and let it run (~15 s for this meeting). Watch for: a progress indication, a working
**Cancel** button, and the rest of the app staying usable.
- Run it once more and **press Cancel mid-run**. Confirm the transcript is unchanged, no labels
  appear, and no `diarization.json` is left behind:
  `ls "$HOME/Library/Application Support/WhisperMeet/Recordings/"*"/diarization.json"`

### 4. The labels — the main event
After a completed run, in **Read** mode:
- Rows should carry chips like `Speaker 1 · inferred`.
- A **legend** above should list the speakers **in ascending order — Speaker 1, Speaker 2, Speaker 3,
  Speaker 4.** If it reads out of order (e.g. "Speaker 2, Speaker 1, Speaker 4, Speaker 3"), that is a
  regression of a bug fixed in `fe0a62a` — report it immediately.
- Many rows will have **no label**, or say **Uncertain**. That is correct and deliberate: roughly 39%
  of rows on this meeting. Do not report abstention as a bug. Report the opposite — a label on every
  row would mean the conservative rule broke.
- Confirm the label is **text**, not colour alone.

### 5. Rename, clear, re-run
- **Rename** a speaker. The field should be labelled **"Your label"** — not "name", not "who".
  Type something ordinary, confirm it appears on that speaker's rows.
- Try an emoji-heavy name (e.g. 🇺🇸 repeated many times). It should clamp, not error. A raw error like
  `The operation couldn't be completed…` is a finding.
- **Analyze Again**: confirm it warns that existing labels are replaced, and that aliases are dropped
  afterwards (cluster numbers are not stable across runs, so carrying a name over would mislabel).
- **Clear**: confirm it asks before destroying labels, and that the transcript survives.

### 6. Label containment — verify by inspection
With labels showing and a speaker renamed to something unmistakable:
- **Copy** the transcript → paste somewhere → it must contain **no** label and **no** alias.
- **Export…** → try two or three of the nine ordinary formats → no labels.
- There should be a separate, explicitly-named **"Transcript with Speaker Labels"** export that
  *does* include them. Confirm both halves.
- Open `notes.md` beside the recording — no labels.
- Search for your alias in the app's search field — it must not match the meeting.

### 7. Accessibility — the part that most needs a human
- **VoiceOver** (⌘F5): navigate the transcript. A labelled row should read something like
  *"Speaker 2, inferred, 12 minutes 4 seconds, …"*. It must say **inferred**. If you ever hear
  "recognized", "identified" or "verified", that is a serious finding — the feature must never imply
  it knows who someone is.
- **Keyboard only**: reach Analyze, Rename, Clear and Analyze Again with Tab/arrows. Anything
  mouse-only is a finding.
- **Dynamic Type**: System Settings → Accessibility → Display → larger text. Confirm labels and the
  legend stay readable and nothing clips.
- **Reduce Motion**: confirm nothing breaks.

### 8. States worth forcing

Fixtures for these exist — generate them first, they are synthetic speech and belong to no one:

```bash
cd /Users/simonwang/Documents/Whisper
./Scripts/bench/diarization/make-ui-fixtures.sh audio /tmp/wm-fixtures
```

- `ui-single-voice.wav` — measured to produce exactly 1 cluster. Import, transcribe, analyse.
- `ui-long-cancel.wav` — 3 hours, analyses in 59 s at 1.5 GB peak. That is the Cancel window; a real
  46-minute meeting finishes in ~15 s, which is too fast to click.
- Import either and leave it **untranscribed** for the no-transcript gating state.
- `make-ui-fixtures.sh models off` parks the installed models so you can read the
  not-installed copy; `models on` restores them. It is a rename, not a delete.

Delete the fixture meetings when you are done.

- **Only one voice**: if any meeting yields a single cluster, the UI must show **no labels at all**
  plus "Only one voice could be told apart" — not every row labelled "Speaker 1". This matters: if
  every row said Speaker 1 and you renamed it, one person's words would be filed under another's name.
- **Model not installed**: check the Settings install row states the size (~21.6 MB), where files go,
  and that only model files are downloaded — never meeting content.

## Report back

For each of the 8 sections: what you saw, with a screenshot reference, and PASS or the finding.

Be specific and be hard to please on wording. This feature's entire defence is that it tells the
truth about its own uncertainty — a confident-sounding label that is wrong is worse than no label. If
any string reads as a claim about a *person* rather than about *audio*, say so.

Finally: confirm `shasum -a 256 "$HOME/Library/Application Support/WhisperMeet/meetings.json"` still
matches what you recorded at the start, and that no recording was modified.
