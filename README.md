# WhisperMeet

**Fast, safe meeting recording and dictation for the Mac — and everything runs on your Mac.**

WhisperMeet records your meetings (your microphone and the other people coming through your Mac's
speakers), turns them into an accurate, timestamped transcript, and helps you summarize, search and
share them. It also lets you dictate into any app: hold a key, speak, let go, and the text appears
where you were typing.

There is no account, no subscription and no cloud service. Your recordings, transcripts and
dictations stay on your Mac — unless you switch on one of the two opt-in features named below.

## Why WhisperMeet

- **Everything runs on your Mac.** Recording, transcription, dictation, summaries, search and
  corrections all use models running on this Mac. Nothing you record, say or type is uploaded. There
  are exactly two exceptions, and both are off until you turn them on: Claude summaries (only with
  your own saved Claude key and a confirmed press — see
  [docs/CLAUDE_SUMMARIES.md](docs/CLAUDE_SUMMARIES.md)) and *Import from a Link* (which downloads
  audio from the site you paste). The speech and language models are downloaded once, when you
  install them.
- **Fast.** On Apple silicon, Qwen3-ASR runs on the Mac's graphics chip. On an Apple M3 Pro, a
  dictation of a few seconds is recognized in about half a second, and a 30-second one in about two.
- **Safe.** Your recording is never changed. If a transcription fails or you cancel it, the audio is
  untouched and you can try again. The microphone and the Mac's sound are kept as separate tracks,
  the app warns you while recording if either goes silent, an interrupted recording is found again
  on the next launch, and no recording or meeting is deleted without asking you first.
- **Accurate, in your language.** Meetings are transcribed after they end, with a full-size model,
  from the finished recording. English and Mandarin are both supported, and a transcript always
  stays in the language that was spoken — it is never translated.

## What you can do

### Record a meeting

- **Start Recording** (⌘R) from the *New Meeting* page or the menu-bar icon. WhisperMeet records
  your microphone and the Mac's system audio — the other people on the call — at the same time.
- **Check before you start.** The *Before recording* panel shows your microphone, the permission to
  record the Mac's audio, and free storage. **Test Recording…** makes an 8-second test and tells you
  whether each side sounds *Good*, *Very quiet*, *Too loud* or has *No signal*.
- **Watch it while it records.** Separate meters for *Microphone (you)* and *System audio (others)*,
  the recording's size on disk, and plain warnings if a side stops, the sound clips, or storage runs
  low.
- **Mark key moments** with **Add Marker** (⇧⌘M). Markers show up on the recording's timeline and in
  exported notes.
- **Stop & Transcribe** when the meeting ends. If you quit while recording, the app asks first; if
  the Mac goes to sleep or you close the lid, the recording is stopped and saved, and the app tells
  you why.

### Bring in recordings you already have

- **Import Recordings…** brings in audio or video files, several at a time, and transcribes them one
  after another.
- **From Finder or Shortcuts:** right-click a file → *Open With → WhisperMeet*, drop it on the Dock
  icon, or choose *Services → Transcribe with WhisperMeet*. WhisperMeet never makes itself the
  default app for your audio files.
- **Watched Folder** (off until you turn it on in Settings): new recordings you put in a chosen
  folder are imported automatically. Your original files are never moved or deleted.
- **Import from a Link** (off until you turn it on in Settings): paste a link to a single video and
  WhisperMeet downloads only its audio, then transcribes it on your Mac. The site you link to sees
  that request, and many sites' terms prohibit downloading, so only use links you have the right to.

### Read, fix and improve a transcript

- **Choose the speech engine** in Settings: *Whisper Large* (the default, best established),
  *Whisper Turbo* (faster), or *Qwen3-ASR 1.7B* (fast and accurate, Apple silicon). Set the meeting
  language to *Detect automatically*, *English* or *Chinese (Mandarin)*.
- **Read along with the audio.** Click any line to move the player there, let the transcript follow
  the playback, and find words with *Find in transcript*.
- **Edit** any line, or right-click it to copy it (with or without its timestamp), re-transcribe
  just that line, or delete it. *Undo* works for removed lines and applied corrections.
- **Spot the shaky parts.** A quality banner points you to lines the engine was unsure of, worst
  first. It never changes anything by itself. See
  [docs/TRANSCRIPT_QUALITY.md](docs/TRANSCRIPT_QUALITY.md).
- **Improve menu** — corrections are shown to you for review before they are applied:
  - *Transcribe Again…* makes a new transcript with the engine and language now chosen in Settings
    (it asks first, and keeps the old one if the new run fails).
  - *Suggest Vocabulary Terms…* finds names and terms in the transcript to add to your vocabulary.
  - *Correct Toward Vocabulary…* and *Apply Replacement Rules…* fix words your vocabulary says were
    misheard.
  - *Correct with Local AI…* (Apple silicon) asks the on-device language model to fix misheard names
    and jargon, optionally guided by a reference file such as a spec or glossary.
  - *Second Opinion (Other Engine)…* transcribes again with the other engine and lets you swap in
    individual lines.
  - *Remove Lines in Another Language…* cleans up a common speech-model mistake, and a banner offers
    *Remove Repeated Lines* when the engine repeated itself.
  - *Analyze Speaker Turns…* (see [Speaker labels](#speaker-labels)).

### Summaries and action items

- **Summarize** a meeting into a summary, key points and action items. By default this runs on a
  language model on your Mac (Apple silicon, installed once from Settings). Claude is an opt-in
  alternative that needs your own API key and asks before sending anything.
- **Pick a style:** *Balanced*, *Brief*, *Detailed* or *Action items*.
- **Pick a template** for the kind of meeting: *General*, *Decision Log*, *1:1*, *Project Update*,
  *Interview* or *Customer Call*.
- **Work your action items:** tick them off, add an owner and a due date, and press the timestamp to
  hear the moment in the recording each one came from, with the supporting quote.

### Find anything you've discussed

- **Search the library** from the toolbar. It searches titles, transcripts and notes, and
  understands filters like `lang:zh`, `min:30m` or `before:2026-06-01`.
- **Ask Meetings** answers a question across all your meetings, or just those with certain tags.
  Each result shows the meeting, the time and the quote, and clicking it jumps to that moment.
  - **Search by meaning** (an optional 490 MB download, Apple silicon) also finds passages worded
    differently from your question — "how much runway do we have" finds "the cash lasts until
    October".
  - **Write an Answer from These Passages** asks the local model for a short answer built only from
    the results on screen. It is shown only if it cites those passages; otherwise you keep the
    passages themselves. Citation is checked per answer, not per sentence, so read the cited
    passages for anything you would act on.

### Organize and share

- **Tags** (up to 12 per meeting), **notes**, and **Pin to Top**. Select several meetings to tag or
  delete them together.
- **Export** a transcript as plain text, timestamped text, Markdown, subtitles (SRT or WebVTT),
  JSON, a chapter list, a chaptered transcript or a web page — or export **Meeting Notes** with the
  summary, transcript and markers together.
- A notification tells you when a transcript is ready, if you are in another app.

### Quick Dictation — talk instead of type, in any app

- Turn it on with *Enable push-to-talk dictation* in Settings or from the menu-bar icon.
- **Hold Right Option, speak, let go.** The text is typed into whatever field you were in — or
  copied to the clipboard if you prefer. You can choose a different key, and switch from
  hold-to-talk to press-once-to-start, press-again-to-stop.
- A small pop-up shows when it is *Listening…*, working, and done.
- **Choose the engine:** *Whisper Turbo* (the default) or *Qwen3-ASR 1.7B* (Apple silicon). The
  model is kept ready while you use it, and after a break it reloads while you are still speaking.
- **Your words, your spelling:** dictation uses your Business Vocabulary and Replacement Rules, and
  can write Chinese as *Simplified*, *Traditional* or *As heard*.
- **Refine with local AI** (optional, Apple silicon) cleans up grammar on your Mac. If it takes too
  long, you get the original text instead of a wait.
- **History** on the *Dictation* page keeps your last 100 dictations, so nothing you said is lost if
  a paste went to the wrong place.
- Up to two minutes per dictation. See
  [docs/QUICK_DICTATION_DESIGN.md](docs/QUICK_DICTATION_DESIGN.md).

### Business Vocabulary

- Add the names, products and jargon you use, or **Import Documents…** (PDF, Word, text, Markdown,
  CSV) to pull terms from your own files.
- **Star** the terms that matter most so they come first when the list is too long to use whole.
- **Replacement Rules** fix a word that is always misheard the same way (`heard → preferred`).
  Dictation applies them before pasting; in a meeting, you review them first.
- Whisper uses your vocabulary as a hint while transcribing. Qwen3-ASR does not take hints, but the
  corrections and rules above still use your list.

### Keep your library safe and small

- **Show Storage…** lists your meetings by the space they use.
- **Shrink…** replaces a meeting's audio with one compressed copy (about 15 MB per hour) and moves
  the originals to the Trash, only when you press it and confirm. You can put them back until you
  empty the Trash.
- **Back up library…** makes dated, checked snapshots (keeping the last 5 by default), and
  **Restore…** shows you exactly what it will do before it does it.
- **Verify Library** checks every recording for missing or damaged audio and changes nothing.
- **Show Recording in Finder** on any meeting takes you to its files. See
  [docs/RECOVERY.md](docs/RECOVERY.md) for what the app does after a crash or a damaged file.

## Privacy, in plain words

| What | Where it goes |
|---|---|
| Your recordings, transcripts, notes, summaries, vocabulary and dictations | Stay on your Mac, in `~/Library/Application Support/WhisperMeet` |
| Speech recognition, dictation, local summaries, corrections, search, speaker analysis | Run on your Mac |
| Models | Downloaded once, when you install each one |
| Claude summaries (off by default) | Only the transcript you choose, only after you save a key and confirm |
| Import from a Link (off by default) | The site you link to sees the download request |
| Copy AI Prompt (Business Vocabulary) | Copies a prompt for you to paste elsewhere — the app sends nothing |

## Speaker labels

Transcripts are not labeled by speaker by default. On Apple silicon you can ask for **Analyze
Speaker Turns…**, which groups the voices in one meeting into *Speaker 1*, *Speaker 2* and so on, on
your Mac. You can rename a label for that meeting ("Me", "Project lead").

It never identifies who someone is, never recognizes a voice across meetings, never guesses anything
about a speaker, and never sends audio or names anywhere. Labels can be wrong — especially when
people talk over each other — and the app says *Uncertain* or *Overlapping voices* rather than
guess. Copies, exports and summaries stay unlabeled unless you choose the labeled export.

## Install

**You need:** a Mac with macOS 15 or later, Homebrew, and the Swift 6.1 command-line tools or Xcode
to build the app. Apple silicon is recommended: on an Intel Mac, Qwen3-ASR and the features that use
the on-device language model are not available.

```bash
Scripts/install-app.sh
open /Applications/WhisperMeet.app
```

Then open **Settings** and install what you want — each is a one-time download:

- **Install Local Whisper** — the default meeting engine (uses Homebrew for FFmpeg and Python).
- **Install Qwen3-ASR** — the fast engine for Apple silicon.
- **Install Local Model** — on-device summaries, *Correct with Local AI*, *Refine with local AI* and
  answers in Ask Meetings (Apple silicon).
- **Install Speaker Analysis** — for *Analyze Speaker Turns…* (Apple silicon).

On your first recording, macOS asks for Microphone and Screen & System Audio Recording permission.
To grant the second in advance, press **Allow…** beside *Mac system audio* in the *Before recording*
panel. If system audio stays silent after you grant it, quit and reopen the app.

`Scripts/install-app.sh` refuses to run while WhisperMeet is open, so an update can never interrupt
a recording, and it puts the previous version back if anything fails. To keep macOS permissions
across rebuilds, create a self-signed code-signing certificate named `WhisperMeet Dev` once
(Keychain Access → Certificate Assistant → Create a Certificate, type *Code Signing*); the script
uses it automatically. Without it, after a rebuild you may need to switch WhisperMeet off and on
again under *Screen & System Audio Recording*. Never run the `.build/WhisperMeet.app` bundle
alongside an installed copy — see
[docs/LIBRARY_INDEX_WIPE_POSTMORTEM_2026-08-14.md](docs/LIBRARY_INDEX_WIPE_POSTMORTEM_2026-08-14.md).

## Disk space

The app itself is about 27 MB. The models are the big part, and you only download the ones you use.

| Component | Approx. size |
|---|---|
| Local Whisper (meetings) | ~1.2 GB runtime + Whisper Turbo ≈ 1.5 GB or Whisper Large ≈ 2.9 GB |
| Whisper Turbo for dictation | ≈ 1.6 GB |
| Qwen3-ASR (Apple silicon) | ≈ 4.5 GB |
| Local Model for summaries and corrections (Apple silicon) | ≈ 4.7 GB (a smaller model on Macs with less than 16 GB of memory) |
| Search by meaning (optional) | 490 MB |
| Speaker Analysis (optional) | ≈ 22 MB |
| Your recordings | ≈ 1.7 GB per recorded hour: `meeting.wav` (48 kHz, 16-bit mono) ≈ 0.35 GB, plus the separate microphone and system-audio tracks ≈ 0.69 GB each — or about 15 MB per hour once you shrink a meeting |

Recordings are never deleted automatically. **Settings → Meeting library → Show Storage…** shows
where the space goes. See [docs/MEETING_STORAGE_DESIGN.md](docs/MEETING_STORAGE_DESIGN.md).

## Keyboard shortcuts

| Keys | Action |
|---|---|
| ⌘R | Start / stop recording |
| ⇧⌘M | Add a marker while recording |
| ⌘, | Settings |
| ⌘/ | Show all keyboard shortcuts |
| Right Option (hold) | Quick Dictation — you can choose another key |

## More documentation

- [Documentation map](docs/README.md) — every guide, by task
- [Product spec](docs/PRODUCT_SPEC.md) · [Recovery](docs/RECOVERY.md) · [Recording
  health](docs/RECORDING_HEALTH.md) · [Test recording](docs/PREFLIGHT_TEST.md) · [Recording
  markers](docs/RECORDING_MARKERS.md)
- [Roadmap](docs/ROADMAP.md) · [Changelog](docs/CHANGELOG.md)

## For developers

```bash
Scripts/quality-check.sh
```

The quality check builds the app, runs every test (no speech model is downloaded), treats warnings
as errors and packages a signed app; GitHub Actions runs the same check on every push to `main`.
`Scripts/setup-local-whisper.sh`, `Scripts/setup-qwen-asr.sh` and
`Scripts/setup-local-summarizer.sh` install the runtimes from the command line, and
`Scripts/qwen-chat` opens an offline Terminal chat with the installed Local Model. Contributors and
coding agents start with [AGENTS.md](AGENTS.md).
