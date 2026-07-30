# WhisperMeet

WhisperMeet is a native macOS meeting recorder focused on producing an accurate transcript after
the meeting. It records microphone and Mac system audio, prepares a clean WAV file, and transcribes
the meeting entirely on this Mac. OpenAI Whisper is the default engine; Apple-silicon Macs can also
install the opt-in open-source Qwen3-ASR engine.

No API key, account, cloud upload, or per-minute fee is required. The transcript remains in the meeting’s original English or Mandarin.

## Requirements

- Apple silicon or Intel Mac running macOS 15 or later
- Swift 6.1 command-line tools or Xcode to build the app
- Homebrew for the one-time local Whisper installation
- Enough free memory for the chosen model: the official repository lists about 10 GB for `large` and 6 GB for `turbo`
- Qwen3-ASR is optional and requires Apple silicon plus about 4.5 GB of storage

## Build and run

```bash
Scripts/build-app.sh
open .build/WhisperMeet.app
```

The build script creates and ad-hoc signs `.build/WhisperMeet.app`. On first recording, macOS asks for Microphone and Screen & System Audio Recording permissions. If system audio is silent after granting permission, quit and reopen the app.

Because the local build is ad-hoc signed, rebuilding changes its code identity. macOS may leave the old **Screen & System Audio Recording** switch visibly enabled even though it belongs to the previous binary. After a rebuild, switch WhisperMeet **off and back on**, quit the app completely with **⌘Q**, and open the newly built app. A stable Apple Development or distribution signature avoids this repeated development-only permission step.

## First-time setup

Open **Settings** and choose **Install Local Whisper**. The bundled installer uses Homebrew to install FFmpeg and Python 3.11, then creates an isolated Python environment under:

```text
~/Library/Application Support/WhisperMeet/Runtime
```

Whisper downloads the selected speech model once, on its first transcription, and stores it under `~/Library/Application Support/WhisperMeet/Models`.

On Apple silicon, Settings also offers **Install Qwen3-ASR**. Its pinned, hash-verified runtime is
stored under `~/Library/Application Support/WhisperMeet/Runtime/Qwen3ASR`. Qwen is opt-in;
Whisper Large remains the default because Qwen still needs validation on long, real meetings.

For a manual installation from this checkout:

```bash
Scripts/setup-local-whisper.sh
Scripts/setup-qwen-asr.sh
```

## Workflow

1. In **Settings**, choose Whisper Large for the best-established English/Mandarin path, Whisper
   Turbo for speed, or the optional Qwen3-ASR trial on Apple silicon.
2. Optionally import business documents under **Business Vocabulary**. Review the extracted terms; only those terms become a local initial prompt for Whisper.
3. Start a meeting recording. Headphones are recommended to prevent remote voices from leaking into the microphone track.
4. Watch the separate microphone and system-audio meters. WhisperMeet warns about a disconnected capture channel, clipping, or low storage while keeping the source tracks on disk.
5. Stop the recording. The selected local engine reads the finished WAV and preserves the original
   language. A missing, failed, or cancelled engine never modifies the recording.
6. Correct the timestamped transcript, copy it, or export it as UTF-8 text.

Recordings, separate microphone/system source tracks, models, and transcripts are stored under `~/Library/Application Support/WhisperMeet`. Each recording folder includes `source-tracks.json`, which records the raw Float32 tracks’ sample rate, frame count, and common-timeline start offsets so the sources remain reusable.

## More features

Beyond the core record → transcribe flow:

- **Quick Dictation** — a push-to-talk hotkey (default Right Option) transcribes a short clip and
  pastes it into any app. On Apple Silicon it uses a Metal-accelerated `mlx-whisper` helper that
  keeps the model warm; this path is independent of the meeting model selection. See
  [docs/QUICK_DICTATION_DESIGN.md](docs/QUICK_DICTATION_DESIGN.md).
- **Preflight test recording** — an ~8-second check that confirms your microphone (and system audio) are actually capturing *sustained* signal before you rely on a real meeting. See [docs/PREFLIGHT_TEST.md](docs/PREFLIGHT_TEST.md).
- **Recording markers** — flag key moments live (⇧⌘M) or in playback; jump back to them and include them in exported notes. See [docs/RECORDING_MARKERS.md](docs/RECORDING_MARKERS.md).
- **Transcript quality review** — flags low-confidence, likely-silence, and repetitive segments (using Whisper’s own metrics), ordered worst-first, so you can spot-check the shakiest parts. It never changes your transcript. See [docs/TRANSCRIPT_QUALITY.md](docs/TRANSCRIPT_QUALITY.md).
- **Claude meeting summaries (opt-in)** — the one non-local feature: paste a Claude API key in Settings and press Summarize to send the transcript to Anthropic’s API for a summary, key points, and action items. Nothing is uploaded without a saved key and an explicit, confirmed press. See [docs/CLAUDE_SUMMARIES.md](docs/CLAUDE_SUMMARIES.md).

Development history is tracked in [docs/CHANGELOG.md](docs/CHANGELOG.md).

## Recording safety and recovery

The recording is the source of truth. Both local engines only read the finished WAV, so a failed
or cancelled transcription leaves the audio untouched and can be retried. The app also keeps
previous-readable copies of its meeting and vocabulary indexes, preserves partial source tracks
when recording finalization fails, and scans for interrupted recording folders on its next launch.

Select **Show Recording in Finder** on any meeting to reach its local files. See [Recording Safety and Recovery](docs/RECOVERY.md) for exact file locations, automatic recovery behavior, manual recovery steps, and the intentionally destructive **Cancel Recording** and **Delete Meeting** actions.

Before capture, the app checks permissions, the default microphone, and available storage. During capture, it monitors the exact microphone and system-audio samples being saved, warns about interruptions and clipping, and prevents idle system sleep. See [Recording Health Monitoring](docs/RECORDING_HEALTH.md) for thresholds and interpretation.

## Speaker limitation

OpenAI Whisper transcribes speech and produces timestamped segments, but it does not perform speaker diarization. This version therefore does not claim to identify different people. The separate microphone and system-audio source files are retained so a local diarization model can be added later without rerecording meetings.

## Verification

```bash
Scripts/quality-check.sh
```

Stage the candidate changes first so newly created files are included. The quality script checks the
complete staged/unstaged diff, runs every test, treats production-build warnings as errors,
and packages a signed app. GitHub Actions runs the same gate on every pull request and push to
`main`. Tests exercise the local process interface, verified CLI options, original-language output,
timestamp parsing, executable discovery, failure handling, index backup recovery, and rebuilding an
interrupted recording without deleting its source tracks. They do not download a speech model.

To build and replace the installed app after quitting WhisperMeet:

```bash
Scripts/install-app.sh
```

The installer refuses to continue while WhisperMeet is running, preventing an update from
interrupting or corrupting an active recording.
