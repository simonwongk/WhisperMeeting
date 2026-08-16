# WhisperMeet v1 Product Specification

## Goal

Build an easy-to-use native Mac application whose primary outcome is the most accurate possible
post-meeting transcript in the meeting’s original language, with all speech processing kept local.

## Requirements

- Record both microphone and Mac system audio.
- Preserve separate source tracks and prepare a combined speech-focused WAV after the meeting.
- Do not require realtime transcription.
- Run open-source speech recognition locally; do not require an API key or upload meeting audio.
  Keep OpenAI Whisper Large as the default and offer the tested Qwen3-ASR path only as an explicit
  Apple-silicon opt-in until it passes long, real-meeting validation.
- Automatically detect English or Mandarin, with an option to select either language for a normally
  single-language meeting.
- Preserve the original spoken language by using the `transcribe` task, never automatic translation.
- Default to the multilingual `large` model for accuracy and offer `turbo` as a faster option.
- Produce editable timestamped transcript segments. When the optional Qwen3-ASR path cannot
  reconcile its forced-alignment word timings with the recognized text, preserve the complete
  transcript text without per-segment timestamps and surface a plain-language notice explaining that
  timing is unavailable — never drop the transcript or the explanation silently.
- Allow PDF, DOCX, TXT, Markdown, and CSV documents to supply a reviewable business-vocabulary list
  used as Whisper’s `initial_prompt`.
- Keep recording and transcription local, and summarize on-device by default: a local mlx_lm model
  (Apple silicon) produces the summary with no API key and nothing uploaded. The one optional cloud
  path is a Claude summary — it is opt-in, requires a user-saved API key plus an explicit, confirmed
  Summarize press, sends only the completed transcript, and never changes the recording or transcript.
- Store recordings and transcripts locally and provide meeting history, editing, copying, export,
  cancellation, and recovery after interruption.
- Treat recorded audio as the source of truth: transcription failures and transcription cancellation
  must never modify or delete the recording.
- Preserve partial raw tracks when recording shutdown or finalization fails, and recover unindexed
  recording folders on the next launch.
- Before recording, show microphone and system-audio permission state, the current default
  microphone, and available storage; refuse to begin when storage is critically low.
- During recording, show independent microphone/system meters derived from the samples written to
  the source tracks, warn about missing capture, clipping, and low storage, and prevent idle system
  sleep.
- Keep a previous-readable backup of meeting and vocabulary indexes. If an index copy cannot be
  read, copy its exact bytes aside before writing anything, and never overwrite bytes that failed to
  parse without first preserving a byte-exact copy — if that copy cannot be written, refuse the write
  entirely. When any index copy is damaged, open the library read-only and block every mutation,
  including recording, import and transcription. Take no automatic action on recording folders: never
  rebuild history from them, and never delete audio. Restoring a damaged library is a manual procedure
  (`docs/RECOVERY.md`); the app does not offer an in-app recovery action.
- Surface recovery and storage failures in plain language, state whether the recording is safe, and
  let the user reveal a meeting's recording in Finder.
- On Macs with Homebrew installed, provide a one-click local runtime installer for FFmpeg, Python
  3.11, and `openai-whisper`; explain the prerequisite in Settings and the README.
- On Apple-silicon Macs, optionally provide a staged, hash-verifying Qwen3-ASR installer that cannot
  run concurrently with capture or transcription and preserves the previous runtime on failure.

## Verified local Whisper contract

- The official package is installed with `pip install -U openai-whisper` and requires FFmpeg.
- Current multilingual model choices include `large` and `turbo`; `large` is the accuracy-first
  default.
- `--task transcribe` returns the original spoken language.
- Omitting `--language` enables language detection; `--language English` and `--language Chinese`
  select a known meeting language.
- `--output_format json` writes text, detected language, and timestamped segments.
- `--initial_prompt` supports custom vocabulary and proper nouns; `--carry_initial_prompt True`
  applies it across decode windows.
- `--model_dir` keeps downloaded model files under the app’s local data directory.

## Explicit limitation

The official OpenAI Whisper repository does not perform speaker diarization. v1 must not present
timestamped Whisper segments as identified speakers. The app preserves microphone and system-audio
source tracks for a future, separately approved local diarization module.

## Recovery boundary

Automatic recovery protects against process failures, app interruption, corrupt indexes, and
incomplete recording finalization. It preserves all audio files it finds. **Cancel Recording** and
**Delete Meeting** are explicit user deletion actions and remain intentionally destructive; the
interface and recovery documentation must state that boundary clearly.
