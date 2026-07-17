# Claude Meeting Summaries (opt-in)

*2026-07-16*

## Goal

Let a user turn a completed meeting transcript into an AI **summary + key points +
action items**, in one click, using the Claude API. This is the first slice of a larger
"connect with Claude" idea; a local, keyless engine is planned as a later piece behind the
same abstraction.

## Privacy boundary (important)

The app records and transcribes entirely on-device with no API key. **This feature is the one
place that promise is knowingly relaxed:** summarizing sends the transcript to Anthropic's
cloud and requires a paid API key. It is therefore **opt-in** — nothing is uploaded unless the
user pastes a key in Settings and explicitly presses Summarize (with a first-run confirmation).

## Decisions

- **Engine:** Claude API over raw HTTPS (`URLSession`) — there is no official Anthropic Swift SDK.
- **Model:** `claude-opus-4-8`.
- **Output:** summary + key points + action items, via **structured outputs** (a JSON schema
  on `output_config.format`) so the result is reliably parseable, not scraped from prose.
- **Language:** the summary is written in the transcript's language (from `languageCode`).

## Components

- **`WhisperCore/MeetingSummarizer.swift`** (pure, testable):
  - `struct MeetingSummary: Codable, Sendable` — `summary: String`, `keyPoints: [String]`,
    `actionItems: [String]`.
  - `protocol MeetingSummarizer: Sendable { func summarize(transcript:language:) async throws -> MeetingSummary }`.
  - `enum SummarizerError: LocalizedError` — `missingAPIKey`, `emptyTranscript`, `requestFailed`,
    `httpStatus(Int, String)`, `refused(String)`, `unreadableResponse`, `emptyResponse`.
- **`WhisperCore/ClaudeSummarizer.swift`** — `struct ClaudeSummarizer: MeetingSummarizer`:
  - Fields: `apiKey`, `model` (default `claude-opus-4-8`), injectable `URLSession` + `baseURL` for tests.
  - `POST /v1/messages`, headers `x-api-key`, `anthropic-version: 2023-06-01`, `content-type`.
  - Body: `model`, `max_tokens` (~4000, non-streaming), `system` (summarize a meeting transcript;
    write summary/key points/action items **in the same language as the transcript**),
    `messages: [user: transcript]`, `output_config.format` = `json_schema` for `MeetingSummary`.
  - Parse the first text block's JSON into `MeetingSummary`. Map 401/400/429/network/
    `stop_reason == "refusal"`/empty to `SummarizerError`.
- **`WhisperMeet/KeychainStore.swift`** — tiny Security-framework wrapper to read/write/delete the
  API key. Link **Security** in `Package.swift` (WhisperMeet target). The key reaches `WhisperCore`
  only as a plain `String` argument.
- **`AppModel`** — `summarize(meetingID:)` mirrors the transcription flow: read the meeting's
  transcript + `languageCode`, load the key, run `ClaudeSummarizer`, store the result. Tracks
  `activeSummarizationID`, per-meeting progress, and errors; `hasClaudeAPIKey` / setter over Keychain.
- **`MeetingRecord`** — add `var summary: MeetingSummary?` (optional → old `meetings.json` decodes
  fine); persisted via the existing `BackupJSONStore`.
- **UI** (`ContentView`):
  - **Settings**: a "Claude Summaries (optional)" section — `SecureField` + Save/Remove, and plain
    text explaining the cloud upload + paid key.
  - **TranscriptDetailView**: a **Summary** section above the transcript. No key → button routes to
    Settings. Key present → "Summarize with Claude" (first-run confirmation alert about the upload);
    running → `ProgressView`; done → summary prose + key-point bullets + action-item list, with
    Copy / Export.

## Tests (WhisperCore)

Stub `URLSession` via a `URLProtocol` subclass:
- Request building — asserts model, transcript in the user message, the same-language instruction,
  and the `json_schema` output config.
- Response parsing — a canned structured response decodes into the expected `MeetingSummary`.
- Errors — HTTP 401 → `.httpStatus`/auth; `stop_reason == "refusal"` → `.refused`; empty content → `.emptyResponse`.

## Invariants preserved

Summarization is purely additive — it never modifies the recording, transcript, or segments.
Local recording/transcription stays keyless and offline; only this opt-in path uses the network.
