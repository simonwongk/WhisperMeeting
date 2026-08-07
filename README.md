# WhisperMeet

WhisperMeet is a native macOS app for people who need an *accurate* record of a meeting more than a
live one. It captures your microphone and the Mac’s system audio as two separate tracks, mixes them
into a clean WAV, and transcribes that finished file using a speech model running on this Mac.

The design is deliberately **post-meeting rather than realtime**. Nothing is streamed or guessed at
while you talk; the completed audio is transcribed once with a large model instead of continuously
with a small one, which is what makes the result worth trusting. Transcripts stay in the language
actually spoken — English or Mandarin — and are never translated.

**Your audio and transcripts stay on this Mac.** Recording, transcription, vocabulary, meeting
summaries, AI transcript correction, and export are fully local, with no account and no per-minute
fee. There is exactly one exception, and it is opt-in: if you save a Claude API key in Settings and
choose the Claude summary engine, that transcript is sent to Anthropic’s API to produce a summary.
Summaries otherwise run on a model on this Mac by default, and nothing leaves the machine without a
saved key and an explicit, confirmed press — see [docs/CLAUDE_SUMMARIES.md](docs/CLAUDE_SUMMARIES.md).

OpenAI Whisper is the default transcription engine; Apple-silicon Macs can additionally install the
opt-in open-source Qwen3-ASR engine. A separate local language model (installed once) powers the
on-device summaries and the AI transcript-correction pass.

Two things the app deliberately will not do: it does not identify **who** is speaking (see [Speaker
limitation](#speaker-limitation)), and it never modifies your recording — a failed or cancelled
transcription always leaves the audio intact and retryable.

Beyond meetings, a **Quick Dictation** hotkey transcribes short clips and pastes them into any app.

## Documentation

Start with the [documentation map](docs/README.md) to find the right guide by task.

| Area | Key documents |
|---|---|
| Product and recovery | [Product spec](docs/PRODUCT_SPEC.md) · [Recovery](docs/RECOVERY.md) · [Recording health](docs/RECORDING_HEALTH.md) · [Preflight test](docs/PREFLIGHT_TEST.md) |
| Feature guides | [Quick Dictation](docs/QUICK_DICTATION_DESIGN.md) · [Recording markers](docs/RECORDING_MARKERS.md) · [Transcript quality](docs/TRANSCRIPT_QUALITY.md) · [Claude summaries](docs/CLAUDE_SUMMARIES.md) |
| Project work | [Work dashboard](docs/tickets-dashboard.html) · [Tickets](docs/TICKETS.md) · [Needs human](docs/NEEDS_HUMAN.md) · [Ticket log](docs/TICKET_LOG.md) |
| Direction and history | [Roadmap](docs/ROADMAP.md) · [Changelog](docs/CHANGELOG.md) |

Contributors and coding agents should start with [AGENTS.md](AGENTS.md).

## Requirements

- Apple silicon or Intel Mac running macOS 15 or later
- Swift 6.1 command-line tools or Xcode to build the app
- Homebrew for the one-time local Whisper installation
- Enough free memory for the chosen model: the official repository lists about 10 GB for `large` and
  6 GB for `turbo`
- Qwen3-ASR is optional and requires Apple silicon plus about 4.2 GB of storage
- Local summaries and AI transcript correction are optional and require Apple silicon plus a one-time
  model download (about 4.7 GB for the default Qwen3-8B; a smaller 4B model on Macs under 16 GB of RAM)
- See [Disk space](#disk-space) for the full footprint of each optional component

## Build and run

```bash
Scripts/build-app.sh
open .build/WhisperMeet.app
```

The build script signs `.build/WhisperMeet.app` with a local **WhisperMeet Dev** code-signing
certificate when one exists in your keychain, and falls back to an ad-hoc signature otherwise. On
first recording, macOS asks for Microphone and Screen & System Audio Recording permissions. If
system audio is silent after granting permission, quit and reopen the app.

A stable signing identity keeps your permission grants across rebuilds. With only an ad-hoc
signature, each rebuild changes the app’s code identity, so macOS may leave the old **Screen &
System Audio Recording** switch visibly enabled even though it belongs to the previous binary; after
such a rebuild, switch WhisperMeet **off and back on**, quit with **⌘Q**, and reopen it. To create
the stable certificate once: Keychain Access → Certificate Assistant → Create a Certificate, name it
`WhisperMeet Dev`, Identity Type Self-Signed Root, Certificate Type Code Signing — then rebuild, and
`build-app.sh` signs with it automatically.

## First-time setup

Open **Settings** and choose **Install Local Whisper**. The bundled installer uses Homebrew to
install FFmpeg and Python 3.11, then creates an isolated Python environment under:

```text
~/Library/Application Support/WhisperMeet/Runtime
```

Whisper downloads the selected speech model once, on its first transcription, and stores it under
`~/Library/Application Support/WhisperMeet/Models`.

On Apple silicon, Settings also offers **Install Qwen3-ASR**. Its pinned, hash-verified runtime is
stored under `~/Library/Application Support/WhisperMeet/Runtime/Qwen3ASR`. Qwen is opt-in; Whisper
Large remains the default because Qwen still needs validation on long, real meetings.

Settings also offers **Install Local Model** — a pinned, hash-verified language model (Qwen3, chosen
by your Mac’s RAM) stored under `~/Library/Application Support/WhisperMeet/Runtime/Summarizer`. It
powers on-device meeting summaries (the default) and AI transcript correction; both share this one
runtime, so enabling correction after summaries needs no further download.

For a manual installation from this checkout:

```bash
Scripts/setup-local-whisper.sh
Scripts/setup-qwen-asr.sh
Scripts/setup-local-summarizer.sh
```

## Disk space

The app itself is a few MB; the speech and language models are the weight, and they download on
first use into `~/Library/Application Support/WhisperMeet/`. Everything except the default Whisper
engine is optional — install only what you use.

| Component | When it installs | Approx. disk |
|---|---|---|
| App bundle | always | a few MB |
| Local Whisper (default engine) | first transcription | ~1.2 GB Python environment + a Whisper model (Turbo ≈ 1.5 GB or Large ≈ 2.9 GB); also uses Homebrew FFmpeg and Python 3.11 |
| Qwen3-ASR (opt-in, Apple silicon) | Settings → Install Qwen3-ASR | ≈ 4.2 GB (ASR + forced-aligner models ≈ 2.3 GB, MLX Python environment ≈ 0.7 GB) |
| Local summaries + AI correction (opt-in, Apple silicon) | Settings → Install Local Model | ≈ 4.7 GB (Qwen3-8B-4bit ≈ 4.3 GB + Python environment ≈ 0.4 GB; a smaller 4B model on Macs under 16 GB of RAM). Summaries and correction share this one runtime. |
| Your recordings | grows with use | 48 kHz mono audio ≈ 1 GB per ~11 hours |

Rules of thumb: a minimal setup (default Whisper only) is about **3–4 GB**; installing everything —
both ASR engines plus local summaries and AI correction — is roughly **12–16 GB** of models and
runtimes, on top of your recordings. Enabling AI correction adds no download once local summaries
are installed. Recordings are never auto-deleted and dominate long-term use, so keep an eye on
`~/Library/Application Support/WhisperMeet/Recordings`.

## Workflow

1. In **Settings**, choose Whisper Large for the best-established English/Mandarin path, Whisper
   Turbo for speed, or the optional Qwen3-ASR trial on Apple silicon.
2. Optionally import business documents under **Business Vocabulary**. Review the extracted terms;
   only those terms become a local initial prompt for Whisper.
3. Start a meeting recording. Headphones are recommended to prevent remote voices from leaking into
   the microphone track.
4. Watch the separate microphone and system-audio meters. WhisperMeet warns about a disconnected
   capture channel, clipping, or low storage while keeping the source tracks on disk.
5. Stop the recording. The selected local engine reads the finished WAV and preserves the original
   language. A missing, failed, or cancelled engine never modifies the recording.
6. Correct the timestamped transcript, copy it, or export it as UTF-8 text.

Recordings, separate microphone/system source tracks, models, and transcripts are stored under
`~/Library/Application Support/WhisperMeet`. Each recording folder includes `source-tracks.json`,
which records the raw Float32 tracks’ sample rate, frame count, and common-timeline start offsets so
the sources remain reusable.

## More features

Beyond the core record → transcribe flow:

- **Quick Dictation** — a push-to-talk hotkey (default Right Option) transcribes a short clip and
  pastes it into any app. On Apple Silicon it uses a Metal-accelerated `mlx-whisper` helper that
  keeps the model warm; this path is independent of the meeting model selection. See
  [docs/QUICK_DICTATION_DESIGN.md](docs/QUICK_DICTATION_DESIGN.md).
- **Preflight test recording** — an ~8-second check that confirms your microphone (and system audio)
  are actually capturing *sustained* signal before you rely on a real meeting. See
  [docs/PREFLIGHT_TEST.md](docs/PREFLIGHT_TEST.md).
- **Recording markers** — flag key moments live (⇧⌘M) or in playback; jump back to them and include
  them in exported notes. See [docs/RECORDING_MARKERS.md](docs/RECORDING_MARKERS.md).
- **Transcript quality review** — flags low-confidence, likely-silence, and repetitive segments
  (using Whisper’s own metrics), ordered worst-first, so you can spot-check the shakiest parts. It
  never changes your transcript. See [docs/TRANSCRIPT_QUALITY.md](docs/TRANSCRIPT_QUALITY.md).
- **Meeting summaries (local by default)** — Summarize produces a summary, key points, and action
  items from a language model running on this Mac — no key, no upload. A **Claude** cloud engine is
  available as an opt-in upgrade: save a Claude API key in Settings and select it to send that
  transcript to Anthropic’s API instead — the one non-local feature, never used without a saved key
  and an explicit, confirmed press. See [docs/CLAUDE_SUMMARIES.md](docs/CLAUDE_SUMMARIES.md).
- **AI transcript correction (local)** — on Apple silicon, the transcript’s **Correct with local
  AI** action asks the on-device model to fix domain terms (names, products, jargon) that speech
  recognition mis-heard, guided by your Business Vocabulary. Corrections are proposed for your
  review, not applied automatically; the recording is never modified, and a transcript you have
  hand-edited is skipped. It reuses the same local model as summaries, so it needs no extra download.

## Recording safety and recovery

The recording is the source of truth. Both local engines only read the finished WAV, so a failed or
cancelled transcription leaves the audio untouched and can be retried. The app also keeps
previous-readable copies of its meeting and vocabulary indexes, preserves partial source tracks when
recording finalization fails, and scans for interrupted recording folders on its next launch.

Select **Show Recording in Finder** on any meeting to reach its local files. See [Recording Safety
and Recovery](docs/RECOVERY.md) for exact file locations, automatic recovery behavior, manual
recovery steps, and the intentionally destructive **Cancel Recording** and **Delete Meeting**
actions.

Before capture, the app checks permissions, the default microphone, and available storage. During
capture, it monitors the exact microphone and system-audio samples being saved, warns about
interruptions and clipping, and prevents idle system sleep. See [Recording Health
Monitoring](docs/RECORDING_HEALTH.md) for thresholds and interpretation.

## Speaker limitation

OpenAI Whisper transcribes speech and produces timestamped segments, but it does not perform speaker
diarization. This version therefore does not claim to identify different people. The separate
microphone and system-audio source files are retained so a local diarization model can be added
later without rerecording meetings.

## Verification

```bash
Scripts/quality-check.sh
```

Stage the candidate changes first so newly created files are included. The quality script checks the
complete staged/unstaged diff, runs every test, treats production-build warnings as errors, and
packages a signed app. GitHub Actions runs the same gate on every pull request and push to `main`.
Tests exercise the local process interface, verified CLI options, original-language output,
timestamp parsing, executable discovery, failure handling, index backup recovery, and rebuilding an
interrupted recording without deleting its source tracks. They do not download a speech model.

To build and replace the installed app after quitting WhisperMeet:

```bash
Scripts/install-app.sh
```

The installer refuses to continue while WhisperMeet is running, preventing an update from
interrupting or corrupting an active recording.
