# Quick Dictation model-selection work log — 2026-07-30

Scope: add a separate Quick Dictation choice between Whisper Turbo and the already approved,
installed Qwen3-ASR 1.7B model. No user meeting, recording, index, or transcript was opened or
changed. The only audio used for real-model verification was `Scripts/bench/clips/en1.wav`.

## Source and architecture checks

- Rechecked the live official OpenAI Whisper repository before changing the local Whisper adapter.
- Rechecked the live official Qwen3-ASR repository before changing the Qwen adapter.
- Inspected the dictation controller, state machine, wire protocol, warm Whisper process, Qwen
  runtime/client, app packaging, installer, diagnostics, and existing tests.
- Confirmed the recorder already creates one ephemeral WAV. The implementation keeps that capture,
  cleanup, paste/clipboard delivery, and history unchanged; model selection is below that boundary.
- Recorded the engine-specific differences: separate Python runtimes and launch arguments; Qwen has
  no `initial_prompt`; meeting-only forced alignment is unnecessary for dictation text.

## Test-first history

The first focused test run used the default Clang cache and failed before compiling the intended red
tests:

```text
error: unable to open output file '/Users/simonwang/.cache/clang/ModuleCache/...':
'Operation not permitted'
```

It was rerun with the repository's temporary cache convention. The intended failures then appeared:

```text
error: cannot find 'DictationTranscriptionEngine' in scope
error: cannot find 'SelectableDictationEngine' in scope
```

After adding the core boundary, another red test established the production Qwen adapter:

```text
error: cannot find 'WarmQwenDictationEngine' in scope
```

The post-review prewarm regression test also failed before implementation:

```text
AttributeError: module 'qwen_dictate_server' has no attribute 'prewarm'
Test run with 1 test failed ... with 6 issues.
```

Implemented coverage now proves model capabilities/default ordering, previous-engine retirement,
retirement of both in-flight and idle-ready helpers, confirmed child-process exit before replacement,
local Qwen launch arguments, shared request/response framing, unchanged WAV-path forwarding,
automatic-language mapping, omission of Whisper-only vocabulary, and prewarm audio shape/options.

Focused verification command:

```text
swift test --disable-sandbox --filter \
'DictationModelSelectionTests|WarmWhisperDictationEngineTests|QwenHelperScriptTests'
```

Actual result:

```text
✔ Test "Replacing the selected dictation model shuts down the resident model" passed
✔ Test "Qwen dictation helper compiles one inference before reporting ready" passed
✔ Test "retire() waits for an in-flight helper to exit before model replacement" passed
✔ Test "retire() waits for an idle helper process to actually exit" passed
✔ Test run with 10 tests passed after 2.040 seconds.
```

## Implementation actions

- Added an independent, persisted dictation model preference. Whisper Turbo remains the default;
  Qwen is opt-in and hidden on unsupported Intel Macs.
- Added a selector to Quick Dictation settings and selected-model diagnostics/repair/self-test text.
- Disabled and explained Business Vocabulary for Qwen instead of silently ignoring a visible promise.
- Added `SelectableDictationEngine`; model replacement now awaits permanent retirement of the prior
  engine before installing and warming the replacement. Retirement waits for child exit and uses a
  five-second forced-stop fallback for an unresponsive helper.
- Added `WarmQwenDictationEngine` on the existing newline-delimited process boundary.
- Added `qwen_dictate_server.py`; it loads the local ASR-only model, runs one 16 kHz mono silent
  inference before readiness, then serves the same dictation request format.
- Kept Qwen offline in the Swift-launched process and omitted the meeting forced aligner to avoid
  unnecessary dictation memory/startup cost.
- Added helper self-healing, fresh-installer copying, bundle packaging, and local lifecycle/timing logs.

## Real installed-model checks

The first real helper attempt was intentionally sandboxed and failed because Metal was unavailable:

```text
libc++abi: terminating due to uncaught exception of type std::runtime_error:
[metal::load_device] No Metal device available.
```

It was rerun outside the GPU restriction using the installed pinned runtime. After the new silent
prewarm, the helper reported:

```json
{"ready": true}
```

The synthetic request and actual response were:

```json
{"wavPath":"/Users/simonwang/Documents/Whisper/Scripts/bench/clips/en1.wav","language":"English","initialPrompt":null}
{"text": "Can you send me the quarterly report by Friday afternoon?", "language": "English", "error": null, "noSpeechProb": null}
```

That response arrived within the first one-second polling window after the request. The earlier
corrected multi-clip benchmark remains the accuracy/speed basis: 0.38-second warm average and zero
measured English WER, Mandarin CER, and code-switch CER on the small synthetic corpus.

## Review and corrections

Two independent read-only reviews found no recording/transcript-safety or AGENTS.md violation. Both
flagged the same lifecycle/performance gaps:

1. readiness occurred before first-inference compilation;
2. replacement requested termination but did not await full process retirement.

Both were fixed. The first re-review then caught that queue drainage still did not prove an
idle-ready child had exited; retirement was tightened to wait for exit, an idle-child regression
test was added, and both independent final re-reviews found no remaining lifecycle defect. A third
finding asked for real output rather than result-only prose; this file records the actual excerpts.

## Final verification evidence

Complete suite:

```text
✔ Test "Qwen dictation helper compiles one inference before reporting ready" passed
✔ Test "retire() waits for an in-flight helper to exit before model replacement" passed
✔ Test "retire() waits for an idle helper process to actually exit" passed
✔ Test run with 176 tests passed after 1.123 seconds.
```

Warnings-as-errors release build:

```text
Building for production...
[5/6] Linking WhisperMeet
Build complete! (24.57s)
```

Package and signature:

```text
/Users/simonwang/Documents/Whisper/.build/WhisperMeet.app
-rw-r--r--@ 1 simonwang staff 2.3K Jul 30 13:57 qwen_dictate_server.py
codesign verification passed
```

Guarded installation and installed-copy verification:

```text
Installed WhisperMeet at /Applications/WhisperMeet.app
If capture permission appears stale, toggle WhisperMeet off and on in Screen & System Audio Recording, then reopen it.
-rw-r--r--@ 1 simonwang staff 2.3K Jul 30 13:57 /Applications/WhisperMeet.app/Contents/Resources/qwen_dictate_server.py
installed app verification passed
```

Syntax/diff checks:

```text
syntax and diff checks passed
```
