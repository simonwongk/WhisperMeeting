# WhisperMeet v1 Product Specification

## Goal

Build an easy-to-use native Mac application whose primary outcome is the most accurate possible post-meeting transcript in the meeting's original language.

## Requirements

- Record both microphone and Mac system audio.
- Preserve separate source tracks and prepare a combined speech-focused recording after the meeting.
- Do not require realtime transcription.
- Submit the completed recording through WhisperAI's asynchronous transcription API.
- Automatically detect English or Mandarin; a meeting normally uses one consistent language.
- Preserve the original spoken language without automatic translation.
- Enable speaker diarization and allow generic speaker labels to be renamed.
- Produce a cleaned, punctuated transcript without filler words.
- Allow PDF, DOCX, TXT, and Markdown documents to supply a reviewable business-vocabulary list for transcription accuracy.
- Do not add AI summarization in v1.
- Store a user-provided `wai_…` key in macOS Keychain. Never hard-code it, log it, add `Bearer`, or put it in a URL.
- Store recordings and transcripts locally, provide meeting history, transcript editing, copying, and text export.
- Handle asynchronous job states, cancellation, API errors, rate limiting, and temporary server failures.

## Verified WhisperAI contract

- `POST /v1/upload` with a raw binary body returns `upload_url`.
- `POST /v1/transcript` submits an asynchronous job.
- `GET /v1/transcript/{id}` reports `queued`, `processing`, `completed`, or `error`.
- `GET /v1/transcript/{id}/paragraphs` supplies a structured readable view when available.
- Parameters: `language_detection`, `speaker_labels`, `punctuate`, `format_text`, `disfluencies`, `keyterms_prompt`, and optional `speakers_expected`.
- Authentication is the raw key in `Authorization`.
