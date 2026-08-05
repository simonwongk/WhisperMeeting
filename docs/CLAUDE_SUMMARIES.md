# Meeting Summaries (local by default, Claude opt-in)

*2026-07-16, updated 2026-08-04 (F164)*

## Goal

Let a user turn a completed meeting transcript into an AI **summary + key points + action items**,
in one click. Summaries are produced **on-device by default** with a local `mlx_lm` model (no API
key, nothing uploaded); **Claude** remains available as an opt-in cloud upgrade behind the same
`MeetingSummarizer` abstraction (F164).

## Privacy boundary (important)

The app records and transcribes entirely on-device with no API key, and **summarization is on-device
by default too** — the local engine keeps the whole feature keyless and offline. The one place that
promise is optionally relaxed is the **Claude engine**: choosing it sends the completed transcript to
Anthropic's cloud and requires a paid API key. It is therefore **opt-in** — nothing is uploaded
unless the user selects the Claude engine, pastes a key in Settings, and explicitly presses Summarize
(with a first-run confirmation). The default local path uploads nothing.

## Decisions

- **Engines (behind one protocol):**
  - **Local (default):** a `Scripts/summarize_local.py` helper runs a pinned Qwen3 model on `mlx_lm`
    (text) in a dedicated `Runtime/Summarizer` venv. Apache-2.0, Apple-silicon only.
  - **Claude (opt-in):** the Claude API over raw HTTPS (`URLSession`) — there is no official
    Anthropic Swift SDK.
- **Local model:** `mlx-community/Qwen3-8B-4bit` (~4.5 GB) on Macs with ≥16 GiB RAM; automatic
  fallback to `mlx-community/Qwen3-4B-4bit` (~2.3 GB) below that. RAM is detected Swift-side
  (`SummarizerRuntime.recommendedRepository`, from `ProcessInfo.physicalMemory`); the installer pins
  each model's revision + `model.safetensors` sha256.
- **Claude model:** `claude-opus-4-8`.
- **Output:** summary + key points + action items. Claude uses **structured outputs** (a JSON schema
  on `output_config.format`); the local model is prompted for the same JSON and the helper's
  `parse_summary` extracts it (degrading to a raw-text summary rather than failing).
- **Language:** the summary is written in the transcript's language (`languageCode`); the
  do-not-translate clause is shared by both engines (`ClaudeSummarizer.systemPrompt`, reused by
  `LocalSummarizer`).

## Components

- **`WhisperCore/MeetingSummarizer.swift`** (pure, testable):
  - `struct MeetingSummary: Codable, Sendable` — `summary`, `keyPoints: [String]`, `actionItems: [String]`.
  - `protocol MeetingSummarizer { func summarize(transcript:language:style:) async throws -> MeetingSummary }`
    (plus a 2-arg convenience defaulting `style` to `.balanced`).
  - `enum SummaryStyle` — `.balanced` / `.brief` / `.detailed` / `.actionItemsFocused` (F63).
  - `enum SummarizationEngine` — `.local` (default) / `.claude`.
  - `enum SummarizerError` — `missingAPIKey`, `emptyTranscript`, `requestFailed`, `httpStatus`,
    `refused`, `responseTruncated`, `unreadableResponse`, `emptyResponse`, and the local cases
    `modelNotInstalled`, `helperFailed(String)`.
- **`WhisperCore/ClaudeSummarizer.swift`** — cloud engine; `POST /v1/messages`, structured-output
  schema, parses the first text block's JSON into `MeetingSummary`; injectable `URLSession`/`baseURL`.
- **`WhisperCore/LocalSummarizer.swift`** — on-device engine + `SummarizerRuntime` (paths, `isInstalled`,
  RAM-based model pick). Spawns the venv python running `summarize_local.py`, streams/cancels like
  `QwenASRClient`, decodes the `--output` JSON into `MeetingSummary`. Reuses the shared system prompt
  and appends an explicit JSON-format directive.
- **`Scripts/summarize_local.py`** — one-shot helper mirroring `qwen_transcribe.py`: `mlx_lm.load` +
  `stream_generate` (thinking disabled), pure `parse_summary` degrade-never-raise, atomic `--output`.
- **`Scripts/setup-local-summarizer.sh`** — dedicated `mlx-lm` venv + pinned model download + sha256
  gate + atomic activation (mirrors `setup-qwen-asr.sh`).
- **`WhisperMeet/KeychainStore.swift`** — reads/writes/deletes the Claude API key (only used by `.claude`).
- **`AppModel`** — `summarizationEngine` (persisted, defaults `.local`), the `makeSummarizer(engine,key)`
  seam, `summarize(id:style:)` with per-engine preconditions (local → model installed; Claude → key),
  `installSummarizer()`, and `isSummarizerInstalled` / `isSummarizerModelInstalled` state.
- **UI** (`ContentView`):
  - **Settings → Summaries**: an engine picker; for local, a model install/repair row + progress; for
    Claude, the `SecureField` + Save/Remove key controls.
  - **TranscriptDetailView**: the Summary section — local shows "Summarize" (no cloud confirmation);
    Claude shows "Summarize with Claude" with the first-run upload confirmation.

## Tests

- **Claude (WhisperCore):** `URLProtocol`-stubbed request building, structured-response decoding, and
  error mapping (`ClaudeSummarizerTests`).
- **Local (WhisperCore):** `LocalSummarizerTests` (fake-process fixture — spawn/parse/cancel,
  modelNotInstalled, degraded-summary, RAM pick, runtime completeness) and
  `SummarizeLocalHelperScriptTests` (runs the real `summarize_local.py` `parse_summary`).
- **Python:** `Scripts/tests/test_summarize_local.py` (pure prompt/parse + `main()` with a fake
  `mlx_lm`), wired into `quality-check.sh` step [3/6].
- **AppModel wiring (WhisperMeet):** `SummarizationEngineWiringTests` — default is `.local`, the chosen
  engine reaches `makeSummarizer`, the full local path stores a summary, and the install-required
  guard fires; `SummaryStyleWiringTests` still proves the style threads through (F81).

## Invariants preserved

Summarization is purely additive — it never modifies the recording, transcript, or segments. Recording
and transcription stay keyless and offline, and **summaries are now local and offline by default**;
only the opt-in Claude engine uses the network.
