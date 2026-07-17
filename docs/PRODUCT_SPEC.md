# WhisperMeet v1 Product Specification

## Goal

Build an easy-to-use native Mac application whose primary outcome is the most accurate possible post-meeting transcript in the meeting’s original language, with all speech processing kept local.

## Requirements

- Record both microphone and Mac system audio.
- Preserve separate source tracks and prepare a combined speech-focused WAV after the meeting.
- Do not require realtime transcription.
- Run the open-source `openai/whisper` package locally; do not require an API key or upload meeting audio.
- Automatically detect English or Mandarin, with an option to select either language for a normally single-language meeting.
- Preserve the original spoken language by using the `transcribe` task, never automatic translation.
- Default to the multilingual `large` model for accuracy and offer `turbo` as a faster option.
- Produce editable timestamped transcript segments.
- Allow PDF, DOCX, TXT, Markdown, and CSV documents to supply a reviewable business-vocabulary list used as Whisper’s `initial_prompt`.
- Do not add AI summarization in v1.
- Store recordings and transcripts locally and provide meeting history, editing, copying, export, cancellation, and recovery after interruption.
- On Macs with Homebrew installed, provide a one-click local runtime installer for FFmpeg, Python 3.11, and `openai-whisper`; explain the prerequisite in Settings and the README.

## Verified local Whisper contract

- The official package is installed with `pip install -U openai-whisper` and requires FFmpeg.
- Current multilingual model choices include `large` and `turbo`; `large` is the accuracy-first default.
- `--task transcribe` returns the original spoken language.
- Omitting `--language` enables language detection; `--language English` and `--language Chinese` select a known meeting language.
- `--output_format json` writes text, detected language, and timestamped segments.
- `--initial_prompt` supports custom vocabulary and proper nouns; `--carry_initial_prompt True` applies it across decode windows.
- `--model_dir` keeps downloaded model files under the app’s local data directory.

## Explicit limitation

The official OpenAI Whisper repository does not perform speaker diarization. v1 must not present timestamped Whisper segments as identified speakers. The app preserves microphone and system-audio source tracks for a future, separately approved local diarization module.
