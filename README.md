# WhisperMeet

WhisperMeet is a native macOS meeting recorder focused on producing an accurate final transcript after the meeting. It captures microphone and system audio separately, prepares a clean WAV recording, submits it to WhisperAI asynchronously, and preserves the original English or Mandarin transcript with speaker labels.

## Requirements

- Apple silicon or Intel Mac running macOS 15 or later
- Swift 6.1 command-line tools or Xcode
- A WhisperAI API key from <https://whisperai.com/developer#keys>

## Build and run

```bash
Scripts/build-app.sh
open .build/WhisperMeet.app
```

The build script creates and ad-hoc signs `.build/WhisperMeet.app`. On first recording, macOS asks for Microphone and Screen & System Audio Recording permissions. If system audio is silent after granting permission, quit and reopen the app.

## Workflow

1. Open **Settings**, enter the `wai_…` key, and save it to Keychain.
2. Optionally import business documents under **Business Vocabulary**. Review the extracted terms; only those terms are sent to WhisperAI.
3. Start a meeting recording. Headphones are recommended to prevent remote voices from leaking into the microphone track.
4. Stop the recording. WhisperMeet uploads the raw WAV body to `POST /v1/upload`, submits an asynchronous job to `POST /v1/transcript`, and polls `GET /v1/transcript/{id}` until completion.
5. Rename speaker labels, correct the editable transcript, copy it, or export it as UTF-8 text.

Recordings, source tracks, and transcripts are stored under `~/Library/Application Support/WhisperMeet`. The API key is stored in macOS Keychain and is sent as the raw `Authorization` value without a `Bearer` prefix.

## Verification

```bash
swift test
swift build
```

The tests cover the upload-submit-poll workflow, exact accuracy parameters, raw-key authentication, rate-limit backoff, preservation of completed text, and speaker-attributed utterances.
