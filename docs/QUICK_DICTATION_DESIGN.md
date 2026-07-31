# Quick Dictation — Design Spec

Status: **approved for planning** (2026-07-21). Feeds `writing-plans` next.

## Goal

Add a **push-to-talk quick-dictation** feature to WhisperMeet that works in *any* app, independent
of the meeting recorder. Hold a customizable key (default **Right ⌥ Option**), speak, release — the
spoken text is transcribed locally by Whisper and **pasted into the currently focused text field**
(falling back to the clipboard). Always-on via a menu-bar presence; launches at login. Target feel:
the same "hold, talk, release, it's there" loop as Wispr Flow, but **fully local**: your audio never
leaves this Mac and no API key is used. (Setup does download open-source dependencies and the
Whisper model files, like the meeting pipeline.)

This is a *separate* function from the meeting record/transcribe pipeline. It shares the local
transcription runtimes — Whisper, and optionally Qwen3-ASR 1.7B on Apple silicon — and pure helpers
in `WhisperCore`.

> **Updated since the original spec.** Dictation is no longer locked to Whisper `turbo`: Settings now
> exposes an engine selector (Whisper `turbo` default; Qwen3-ASR 1.7B MLX 8-bit opt-in on Apple
> silicon). The business-vocabulary `initial_prompt` nudge applies to the Whisper engine only — Qwen
> does not consume it, and Settings discloses that limitation.

## Non-goals (v1)

- No cloud/streaming ASR. (Wispr Flow feels instant because it streams to its cloud; we stay local.)
- No live word-by-word streaming — Whisper is batch; we transcribe the finished clip.
- No AI/Claude text cleanup of dictated text (adds latency + network; breaks the local-instant
  feel).
- No multiple hotkey profiles, no per-app rules. (**Superseded in Round 7:** a persistent local
  dictation history *was* added as a reliability fallback — see `docs/CHANGELOG.md`. It stays
  on-device; retention controls / an off switch are tracked as follow-ups.)
- No speaker diarization (project invariant — never present segments as identified speakers).

## Relationship to project invariants

- **Local-only preserved.** Dictation never touches the network. The lone existing network exception
  (opt-in Claude summaries) is untouched and does not apply here.
- **Original language only.** Whisper always uses `--task transcribe`; Qwen returns original-language
  recognition. Language auto-detect or a pinned English/Mandarin, reusing `WhisperLanguage`. Never
  translate.
- **`WhisperCore` stays framework-free and `Sendable`.** All AppKit/AVFoundation/CoreGraphics code
  lives in `WhisperMeet`; all pure logic is in `WhisperCore` and unit-tested headlessly.
- **Ephemeral, non-destructive.** Dictation clips are temporary scratch WAVs, deleted after
  transcription. Dictation never reads, writes, or deletes anything under `Recordings/` and never
  mutates the meetings index. It cannot regress "the recording is the source of truth."

## Decisions (locked with the user)

| Decision | Choice |
|---|---|
| Transcription engine | Selectable in Settings: Local Whisper `turbo` (**default**) or Qwen3-ASR 1.7B MLX 8-bit (Apple silicon, opt-in). Vocabulary `initial_prompt` applies to Whisper only. |
| Instant-feel strategy | **Warm helper**: a resident Python process holds the model in RAM |
| Presence | Menu-bar icon + **launch at login**; runs in background with window closed |
| Text delivery | **Auto-paste** into focused field (clipboard + synthesized ⌘V); **clipboard fallback** |
| Trigger | Hold **Right ⌥ Option** (customizable); hold-to-talk default, toggle mode optional |

## User flow

```
[any app, anywhere]
  hold Right ⌥ ──► pill appears bottom-center: 🔴 "Listening…" + live mic level
     (speak)
  release ⌥    ──► pill: "Transcribing…" (spinner)
     warm Whisper turbo transcribes the clip (few hundred ms once warm)
  success      ──► text pasted into focused field via ⌘V; pill flashes ✓, fades out
```

Fallback / edge branches:
- **No Accessibility permission or no focused field** → text left on clipboard + a user notification
  ("Transcript copied — press ⌘V"). Pill shows "Copied to clipboard".
- **Clip too short** (< ~0.35 s, an accidental tap) → discarded silently, pill dismissed.
- **Empty transcript** (silence) → pill shows "Didn't catch that", fades; nothing pasted.
- **Press while busy** (a dictation still transcribing/delivering) → ignored; brief "busy" flash.
- **A meeting is actively recording** → dictation hotkey is inert (mic-contention guard); menu bar
  and pill explain why. Symmetrically, starting a meeting while dictating is blocked until release.
- **Engine/helper failure** → pill shows a short error; text (if any) still lands on clipboard.

## Architecture

```
DictationController  (@MainActor, WhisperMeet)                 ← feature orchestrator
 ├── HotkeyMonitor         (CGEventTap — WhisperMeet)          key hold/release → events
 ├── MicDictationRecorder  (AVAudioEngine — WhisperMeet)       mic-only 16 kHz mono → scratch WAV
 ├── DictationOverlay      (non-activating NSPanel — WhisperMeet)  the pill (never steals focus)
 ├── TextInjector          (NSPasteboard + CGEvent ⌘V — WhisperMeet)  deliver text
 └── DictationEngine       (protocol — WhisperCore)
        ├── WarmWhisperDictationEngine  (WhisperCore)          drives resident helper over stdin/stdout
        └── BatchWhisperDictationEngine (WhisperCore)          CLI fallback (wraps LocalWhisperClient)

DictationSession  (pure state machine — WhisperCore, TESTED)   drives the controller's transitions
whisper_dictate_server.py  (Python, installed in the venv)     loads turbo once; serves over stdin/stdout
```

The controller is created alongside `recorder`/`store` in `AppModel.init(store:recorder:defaults:)`
(the existing dependency-injection seam) or in `AppEntry` and passed to the scene. It observes
`AppModel.recordingState` for the mic-contention guard.

## Components — `WhisperCore` (pure, `Sendable`, unit-tested)

### `WAVWriter`
Extract the WAV-building logic currently **private** inside `AudioCaptureEngine` (`wavHeader`,
little-endian `Data` helpers) into a reusable, tested type.
- API: `WAVWriter(sampleRate: Int, channels: Int = 1)`, `append(_ samples: [Float])`,
  `finalize() -> Data`; plus `static func wavData(fromFloatSamples:sampleRate:) -> Data`.
- 16-bit PCM, mono; clamps samples to [-1, 1].
- **Refactor:** `AudioCaptureEngine`/`FloatTrackMixer` switch to `WAVWriter` so there's one WAV
  path. Meeting output must stay byte-identical (48 kHz, 16-bit mono) — covered by a regression
  test.
- Tests: RIFF/fmt/data chunk sizes, byte-rate/block-align, sample count, duration, clamping.

### `DictationSession`
Pure state machine.
- States: `idle`, `listening(startedAt)`, `transcribing`, `delivering`, `done`, `failed(Reason)`.
- Events: `startPressed`, `endPressed(clipDuration)`, `transcriptReady(String)`,
  `delivered(Method)`, `failed(Reason)`, `dismiss`.
- Guards: reject `startPressed` unless `idle`; on `endPressed`, if `clipDuration < minClipDuration`
  → back to `idle` (discard); empty transcript → `failed(.emptyTranscript)`.
- Emits the next action for the controller (start recorder / begin transcription / deliver / reset).
- Tests: every transition + guard; too-short discard; busy rejection; empty-transcript path.

### `DictationTextCleanup`
- `static func clean(_ raw: String) -> String`: strip Whisper's leading space, trim, collapse
  internal whitespace/newline runs to single spaces; return `""` if only whitespace.
- Tests: leading-space strip, newline collapse, whitespace-only → empty, CJK text untouched.

### `DictationWireProtocol`
Codable request/response + **newline-delimited JSON** framing for the helper's stdin/stdout.
- `DictationRequest { wavPath: String, language: String?, initialPrompt: String? }`
- `DictationResponse { text: String?, language: String?, error: String? }`
- `static func encodeLine(_ value) -> Data` (JSON + `\n`) / `decodeResponse(line:)` /
  `takeLine(_ buffer:)`.
- Tests: round-trip encode/decode, newline framing, partial + multi-line splitting, error-field
  decode — pure, so tested without spawning the helper.

### `DictationEngine` protocol + implementations
- `protocol DictationEngine: Sendable { func transcribe(wavAt: URL, language: WhisperLanguage, initialPrompt: String?) async throws -> DictationResult }`
- `WarmWhisperDictationEngine`: owns the helper lifecycle — locate the venv python via
  `LocalWhisperRuntime`, spawn `whisper_dictate_server.py` with `--model turbo --model-dir …`, and
  drive it over the child process's **stdin/stdout** using `DictationWireProtocol`
  (newline-delimited JSON). Waits for a `{"ready": true}` line before use; serializes requests on a
  private queue with a watchdog that bounds each read (terminating a hung helper); `shutdown()`
  evicts the model.
- `BatchWhisperDictationEngine`: wraps the existing `LocalWhisperClient` (CLI per clip) as a
  correctness fallback if the helper can't start; also handy for tests. ~2–4 s per clip.

## Components — `WhisperMeet` (framework code, not headlessly tested)

### `HotkeyMonitor`
- `CGEventTap` at `.cgSessionEventTap` listening for `.flagsChanged` (modifier keys) and, for
  non-modifier custom keys, `.keyDown`/`.keyUp`.
- Detect **Right Option**: keyCode `0x3D`, disambiguated from left Option via the device-dependent
  right-alt flag. Emits `onPressStart` / `onPressEnd` on the main actor.
- Config `DictationHotkey { keyCode, mode: .hold | .toggle }`; hold vs toggle handled here.
- Exposes `isTrusted` (`AXIsProcessTrusted`) and `requestPermission()`
  (`AXIsProcessTrustedWithOptions` with prompt). If tap creation fails while trusted, surfaces a
  hint to also enable **Input Monitoring**.

### `MicDictationRecorder`
- `AVAudioEngine` input-node tap → `AVAudioConverter` to **16 kHz mono Float32** → `WAVWriter` →
  scratch WAV in the temp dir (not `Recordings/`).
- Emits RMS level (~15 Hz) for the pill. Deletes the WAV after transcription.
- Mic permission via `AVCaptureDevice.authorizationStatus/requestAccess(for: .audio)` (same pattern
  as `AudioCaptureEngine.requestMicrophoneAccess`). **No ScreenCaptureKit → no Screen Recording
  permission.**

### `DictationOverlay`
- Borderless `NSPanel`, `.nonactivatingPanel`; `canBecomeKey = false`; level `.statusBar`;
  `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]`. Positioned
  bottom-center of the active screen. Hosts a small SwiftUI pill via `NSHostingView`.
- Pill states: Listening (mic-level meter), Transcribing (spinner), Done ✓, Copied-to-clipboard,
  Didn't-catch-that, Error. Fade in/out. **Never becomes key — never steals focus from the target
  app.**

### `TextInjector`
- `NSPasteboard.general` `clearContents` + `setString`; then synthesize ⌘V via `CGEvent` (keyCode
  `9` with `.maskCommand`, keyDown+keyUp) posted to `.cgSessionEventTap`, with a small settle delay
  after setting the clipboard.
- If `!AXIsProcessTrusted` → skip ⌘V, post a `UNUserNotification` ("Transcript copied — press ⌘V").
- v1 leaves the transcript on the clipboard (matches "…or go to clipboard"); prior-clipboard restore
  is deferred.

### `DictationController` (`@MainActor ObservableObject`)
- Wires
  `HotkeyMonitor → DictationSession → MicDictationRecorder → DictationEngine → TextInjector → DictationOverlay`.
  Owns enable/disable, permission state, warm-up trigger, idle-evict timer, and the **mic-contention
  guard** (observes `AppModel.recordingState`; inert while a meeting records).
- Publishes state for the menu bar and settings; background work via `Task.detached`. Exactly one
  dictation at a time (enforced by `DictationSession`).

### Menu bar + launch at login
- `MenuBarExtra` scene in `AppEntry`, icon reflecting idle/listening/transcribing; menu:
  Enable/Disable dictation, Open Settings, Quit. Keeps the app alive with its window closed.
- `SMAppService.mainApp.register()/unregister()` behind a "Launch at login" toggle.

### Settings
New **"Quick Dictation"** `Section` in the existing `SettingsView` `Form` (same `@Published` +
`UserDefaults { didSet }` pattern as `selectedEngine`/`selectedLanguage`): Enable toggle · trigger
key recorder + Hold/Toggle · language (Auto/English/Mandarin) · delivery (Auto-paste/Clipboard-only)
· use business vocabulary as `initial_prompt` (optional) · Launch-at-login · live permission rows
(Microphone ✓/✗, Accessibility ✓/✗) with "Open System Settings" buttons · warm-model status +
idle-evict minutes.

## Python helper — `whisper_dictate_server.py`

- Args: `--model turbo`, `--model-dir <cache>`.
- Loads the Whisper model **once**, then prints `{"ready": true}` on stdout. Reads newline-delimited
  JSON requests `{wavPath, language?, initialPrompt?}` on stdin, runs
  `model.transcribe(wavPath, task="transcribe", language=…, initial_prompt=…, fp16=False)`, and
  replies with one JSON line `{text, language}` or `{error}` on stdout.
- Exits when stdin closes (the controller terminates it to evict the model / free RAM); re-warmed on
  demand. Wraps each request in try/except so one bad request can't kill the daemon. **No extra
  Python deps** (Whisper already decodes audio via FFmpeg).
- Installed by `Scripts/setup-local-whisper.sh` into the venv and bundled into the `.app` by
  `Scripts/build-app.sh` (mirrors how the setup script is already bundled).

## Data, config, storage

- No socket or port: the helper is a child process driven over its stdin/stdout pipes.
- Scratch WAVs: system temp dir, deleted after use. Nothing under `Recordings/`.
- Model reused from the existing `…/WhisperMeet/Models` cache (no second download).
- `UserDefaults` keys: `dictationEnabled`, `dictationHotkeyKeyCode`, `dictationHotkeyMode`,
  `dictationLanguage`, `dictationDelivery`, `dictationUseVocabulary`, `dictationLaunchAtLogin`,
  `dictationIdleEvictMinutes`.

## Permissions & honest caveats

- **Microphone** — existing `NSMicrophoneUsageDescription`; standard TCC prompt.
- **Accessibility** — required for both the `CGEventTap` push-to-talk listener and ⌘V injection.
  Prompted via `AXIsProcessTrustedWithOptions`. If the tap still won't create, guide the user to
  also enable **Input Monitoring**.
- **No Screen Recording** — dictation uses `AVAudioEngine`, not ScreenCaptureKit.
- **Ad-hoc-signing caveat** — the Accessibility grant is bound to the binary identity, so a rebuild
  can reset it (dev-time annoyance). Documented; a stably-signed app in `/Applications` keeps it.

## Latency budget (warm helper)

| Step | Target |
|---|---|
| Key-down → pill visible | < 150 ms |
| Warm-up (once, on enable / first press) | ~2–4 s |
| Release → transcript (short clip, warm) | typically < 1 s (~200–500 ms compute) |
| Transcript → pasted | < 100 ms |

Cold (no warm helper) fallback via `BatchWhisperDictationEngine`: ~2–4 s + compute (documented as
not the target feel).

## Concurrency

`DictationController` and UI are `@MainActor`. Recorder capture, engine stdin/stdout I/O, and helper
process management run off the main actor (`Task.detached` / async). `DictationSession` guarantees a
single in-flight dictation. Warm engine serializes requests.

## Logging & observability

Per the user's "keep logs of what you've done":
- **Runtime:** `os.Logger` subsystem `com.whispermeet.app`, category `dictation` — enable/disable,
  warm start/evict, hotkey down/up, clip duration, transcription latency, delivery method (paste vs
  clipboard), and errors. (Mirrors the existing "phase timings to the unified log" precedent.)
- **Project worklog:** each build/test/review round is appended to `docs/CHANGELOG.md` as a new
  "Round — Quick Dictation …" entry, matching the established autonomous-improvement format.

## Testing

- **`WhisperCore` (Swift Testing, headless):** `WAVWriter` (bytes/header/duration/clamp + meeting
  byte-identity regression), `DictationSession` (all transitions + guards), `DictationTextCleanup`,
  `DictationWireProtocol` (round-trip + framing via stub transport). Target: meaningfully grows the
  suite (currently 67 tests).
- **`WhisperMeet`:** no headless tests (AppKit/CGEvent), consistent with the project. Covered by a
  **manual verification checklist** (below).
- **Gate:** `swift test` + warnings-as-errors release build via `Scripts/quality-check.sh`.

### Manual verification checklist
1. Enable dictation in Settings; grant Microphone + Accessibility when prompted.
2. Close the main window — menu-bar icon remains; app still running.
3. In TextEdit / Notes / a browser field: hold Right ⌥, speak, release → text pastes into the field.
4. Focus nothing pasteable (or revoke Accessibility) → text lands on clipboard + notification.
5. Speak Mandarin → Mandarin text (no translation).
6. Tap the key without speaking → nothing pasted, pill dismisses.
7. Start a meeting recording → dictation hotkey is inert with an explanation; stop → it works again.
8. Toggle Launch-at-login → verify the login item registers.
9. Verify no Screen Recording prompt ever appears for dictation.

## Build / packaging changes (no new SPM dependencies)

- `WhisperMeet` linker settings add: `ServiceManagement` (login item), `UserNotifications`
  (clipboard-fallback toast); ensure `CoreGraphics`/`ApplicationServices` (CGEvent, AX) available.
- `Scripts/setup-local-whisper.sh`: install `whisper_dictate_server.py` into the venv.
- `Scripts/build-app.sh`: bundle the helper script into the `.app`.
- `Resources/Info.plist`: no new usage strings strictly required (Accessibility/Input Monitoring
  have no Info.plist keys); mic string already present.

## Risks & mitigations

- **Warm model RAM (~1.5–3 GB)** while active → idle-evict timer; re-warm on demand.
- **Right vs left Option disambiguation** → match keyCode `0x3D` + device-dependent right-alt flag;
  verify on the target Mac; fall back to plain Option if the device flag is unreliable.
- **Accessibility grant reset on rebuild** (ad-hoc signing) → documented; use `install-app.sh` flow.
- **Mic contention with an active meeting** → hard guard both directions.
- **Helper crash/hang** → health-check + restart; on repeated failure, degrade to
  `BatchWhisperDictationEngine` and surface a clear error.

## Deferred / future

AI/Claude text cleanup; live streaming words; dictation history; multiple hotkey profiles;
prior-clipboard restore after paste; per-app behavior; auto-type (keystroke) delivery mode.

## Acceptance criteria

- Holding the trigger anywhere shows the pill < 150 ms and animates mic level.
- Releasing (warm) pastes accurate local transcript into the focused field, typically < 1 s.
- Clipboard + notification fallback works with no Accessibility / no focused field.
- Works with the main window closed; menu bar present; launches at login when enabled.
- English **and** Mandarin transcribe in the original language (never translated).
- Dictation and meeting recording never contend for the mic.
- No Screen Recording permission is requested for dictation.
- New `WhisperCore` tests pass; `Scripts/quality-check.sh` is green.
