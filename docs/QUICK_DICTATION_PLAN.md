# Quick Dictation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a push-to-talk global dictation feature — hold a key anywhere, speak, release, and the local Whisper transcript is pasted into the focused field (clipboard fallback).

**Architecture:** A new `@MainActor DictationController` in `WhisperMeet` orchestrates a `CGEventTap` hotkey monitor, an `AVAudioEngine` mic-only recorder, a floating non-activating overlay, and a text injector. Transcription runs through a resident Whisper "warm helper" (a Python process holding the `turbo` model in RAM, driven over stdin/stdout newline-delimited JSON). All pure logic (state machine, WAV writer, wire protocol, cleanup) lives in `WhisperCore` and is unit-tested headlessly.

**Tech Stack:** Swift 6 tools / Swift 5 language mode, SwiftPM, macOS 15+, AVFoundation, CoreGraphics (CGEventTap/CGEvent), AppKit (NSPanel), ServiceManagement (SMAppService), UserNotifications, Python `openai-whisper` (existing venv). No new SPM dependencies.

## Global Constraints

- `WhisperCore` stays framework-free, `Sendable`, and unit-tested — no AppKit/AVFoundation/CoreGraphics imports there. All Apple-framework code lives in `WhisperMeet`.
- Local-only: dictation never touches the network. Never translate — always `task="transcribe"`.
- Dictation is ephemeral: scratch WAVs go in `FileManager.default.temporaryDirectory` and are deleted after use. Dictation never reads/writes/deletes anything under `Recordings/` and never mutates the meetings index.
- No speaker diarization; `TranscriptSegment.speaker` stays `nil` (not used here).
- Tests use **Swift Testing** (`import Testing`, `@Test("…")`, `#expect`), not XCTest. Only `WhisperCore` is tested.
- Build must stay warnings-clean (release build is warnings-as-errors via `Scripts/quality-check.sh`): do not leave unused private members behind after a refactor.
- Model default for dictation is `WhisperModel.turbo`. Trigger default is `DictationHotkey.rightOption` (keyCode `61`, hold mode).
- Runtime logging via `os.Logger(subsystem: "com.whispermeet.app", category: "dictation")`. Each completed round is appended to `docs/CHANGELOG.md`.

## File structure

**Create (`WhisperCore`, pure + tested):**
- `Sources/WhisperCore/WAVWriter.swift` — WAV byte building (extracted from `AudioCaptureEngine`).
- `Sources/WhisperCore/DictationTextCleanup.swift` — whitespace/newline normalization.
- `Sources/WhisperCore/DictationSession.swift` — push-to-talk state machine.
- `Sources/WhisperCore/DictationProtocol.swift` — `DictationRequest`/`Response`, wire framing, `DictationResult`, `DictationEngine` protocol, `DictationHotkey`.
- `Sources/WhisperCore/WarmWhisperDictationEngine.swift` — resident helper lifecycle + stdin/stdout transport; `BatchWhisperDictationEngine` fallback.

**Create (`WhisperMeet`, framework):**
- `Sources/WhisperMeet/Dictation/MicDictationRecorder.swift`
- `Sources/WhisperMeet/Dictation/HotkeyMonitor.swift`
- `Sources/WhisperMeet/Dictation/TextInjector.swift`
- `Sources/WhisperMeet/Dictation/DictationOverlay.swift`
- `Sources/WhisperMeet/Dictation/DictationController.swift`

**Create (runtime):**
- `Scripts/whisper_dictate_server.py` — the warm helper.

**Create (tests):**
- `Tests/WhisperCoreTests/WAVWriterTests.swift`
- `Tests/WhisperCoreTests/DictationTextCleanupTests.swift`
- `Tests/WhisperCoreTests/DictationSessionTests.swift`
- `Tests/WhisperCoreTests/DictationProtocolTests.swift`

**Modify:**
- `Sources/WhisperMeet/AudioCaptureEngine.swift` — route WAV header through `WAVWriter`; delete the now-dead private `wavHeader` + `Data` extension.
- `Sources/WhisperCore/LocalWhisperClient.swift` — add runtime path helpers; make `WhisperLanguage.commandLineValue` public (in `TranscriptModels.swift`).
- `Sources/WhisperCore/TranscriptModels.swift` — `public var commandLineValue`.
- `Package.swift` — link `ServiceManagement`, `UserNotifications`.
- `Sources/WhisperMeet/AppEntry.swift` — create `DictationController`, add `MenuBarExtra`, inject into `ContentView`/`SettingsView`.
- `Sources/WhisperMeet/AppModel.swift` — expose `isRecordingActive` for the mic-contention guard.
- `Sources/WhisperMeet/ContentView.swift` — add "Quick Dictation" settings `Section`.
- `Scripts/setup-local-whisper.sh` — copy the helper into the runtime dir.
- `Scripts/build-app.sh` — bundle the helper into the `.app`.

---

## Task 1: `WAVWriter` (extract + generalize WAV bytes)

**Files:**
- Create: `Sources/WhisperCore/WAVWriter.swift`
- Test: `Tests/WhisperCoreTests/WAVWriterTests.swift`
- Modify: `Sources/WhisperMeet/AudioCaptureEngine.swift:624` (call site), delete `640-656` (`wavHeader`) and `704-713` (`Data` extension)

**Interfaces:**
- Produces: `WAVWriter.header(sampleRate: UInt32, dataByteCount: UInt32) -> Data`, `WAVWriter.pcm16Data(from: [Float]) -> Data`, `WAVWriter.wavData(from: [Float], sampleRate: Int) -> Data`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/WhisperCoreTests/WAVWriterTests.swift
import Testing
import Foundation
@testable import WhisperCore

@Test("WAV header is the canonical 44-byte 16-bit mono PCM header")
func wavHeaderBytes() {
    let header = WAVWriter.header(sampleRate: 16_000, dataByteCount: 8)
    #expect(header.count == 44)
    #expect(Array(header) == [
        0x52,0x49,0x46,0x46, 0x2C,0x00,0x00,0x00, 0x57,0x41,0x56,0x45, // RIFF, 44, WAVE
        0x66,0x6D,0x74,0x20, 0x10,0x00,0x00,0x00, 0x01,0x00, 0x01,0x00, // "fmt ", 16, PCM, mono
        0x80,0x3E,0x00,0x00, 0x00,0x7D,0x00,0x00, 0x02,0x00, 0x10,0x00, // 16000, 32000, align 2, 16 bits
        0x64,0x61,0x74,0x61, 0x08,0x00,0x00,0x00                        // "data", 8
    ])
}

@Test("PCM16 encoding clamps and scales to little-endian Int16")
func pcm16Encoding() {
    let data = WAVWriter.pcm16Data(from: [0, 1, -1, 0.5, 2])
    #expect(Array(data) == [
        0x00,0x00, 0xFF,0x7F, 0x01,0x80, 0xFF,0x3F, 0xFF,0x7F // 0, 32767, -32767, 16383, clamped→32767
    ])
}

@Test("wavData concatenates a header sized to the sample payload")
func wavDataAssembly() {
    let wav = WAVWriter.wavData(from: [0, 1, -1], sampleRate: 16_000)
    #expect(wav.count == 44 + 6)
    #expect(Array(wav.prefix(4)) == [0x52,0x49,0x46,0x46]) // RIFF
    // data chunk length field (bytes 40..44) == 6
    #expect(Array(wav[40..<44]) == [0x06,0x00,0x00,0x00])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WAVWriter`
Expected: FAIL — `cannot find 'WAVWriter' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/WhisperCore/WAVWriter.swift
import Foundation

/// Builds 16-bit PCM mono WAV bytes. Shared by the meeting mixer and quick-dictation capture so
/// there is exactly one WAV path in the codebase.
public enum WAVWriter {
    /// The canonical 44-byte RIFF/WAVE header for 16-bit mono PCM at `sampleRate`.
    public static func header(sampleRate: UInt32, dataByteCount: UInt32) -> Data {
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func le<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        ascii("RIFF"); le(36 &+ dataByteCount); ascii("WAVE")
        ascii("fmt "); le(UInt32(16)); le(UInt16(1)); le(UInt16(1))
        le(sampleRate); le(sampleRate &* 2); le(UInt16(2)); le(UInt16(16))
        ascii("data"); le(dataByteCount)
        return data
    }

    /// Little-endian Int16 samples, clamped to [-1, 1].
    public static func pcm16Data(from samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            var value = Int16(clamped * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// A complete WAV file (header + PCM payload) for the given float samples.
    public static func wavData(from samples: [Float], sampleRate: Int) -> Data {
        let pcm = pcm16Data(from: samples)
        var data = header(sampleRate: UInt32(sampleRate), dataByteCount: UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter WAVWriter`
Expected: PASS (3 tests).

- [ ] **Step 5: Route `AudioCaptureEngine` through `WAVWriter` and delete dead code**

In `Sources/WhisperMeet/AudioCaptureEngine.swift`, add `import WhisperCore` at the top if not already imported. Replace the header write at line 624:

```swift
        try output.seek(toOffset: 0)
        output.write(WAVWriter.header(
            sampleRate: UInt32(sampleRate),
            dataByteCount: dataByteCount
        ))
        return Double(writtenFrames) / sampleRate
```

Then delete the now-unused `private static func wavHeader(...)` (lines 640-656) and the `private extension Data { appendASCII / appendLittleEndian }` (lines 704-713). Verify nothing else references them:

Run: `grep -n "wavHeader\|appendASCII\|appendLittleEndian" Sources/WhisperMeet/AudioCaptureEngine.swift`
Expected: no matches.

- [ ] **Step 6: Build to confirm the meeting path still compiles**

Run: `swift build`
Expected: build succeeds, no warnings.

- [ ] **Step 7: Commit**

```bash
git add Sources/WhisperCore/WAVWriter.swift Tests/WhisperCoreTests/WAVWriterTests.swift Sources/WhisperMeet/AudioCaptureEngine.swift
git commit -m "feat: extract WAVWriter into WhisperCore (shared WAV path)"
```

---

## Task 2: `DictationTextCleanup`

**Files:**
- Create: `Sources/WhisperCore/DictationTextCleanup.swift`
- Test: `Tests/WhisperCoreTests/DictationTextCleanupTests.swift`

**Interfaces:**
- Produces: `DictationTextCleanup.clean(_ raw: String) -> String`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/WhisperCoreTests/DictationTextCleanupTests.swift
import Testing
@testable import WhisperCore

@Test("clean trims and collapses whitespace, preserving CJK")
func cleanNormalizes() {
    #expect(DictationTextCleanup.clean(" Hello world ") == "Hello world")
    #expect(DictationTextCleanup.clean("Hello\n\n  world") == "Hello world")
    #expect(DictationTextCleanup.clean("   ") == "")
    #expect(DictationTextCleanup.clean(" 你好") == "你好")
    #expect(DictationTextCleanup.clean("你好 世界") == "你好 世界")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DictationTextCleanup`
Expected: FAIL — `cannot find 'DictationTextCleanup' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/WhisperCore/DictationTextCleanup.swift
import Foundation

/// Normalizes raw Whisper output for dictation: strips Whisper's leading space, collapses runs of
/// whitespace/newlines to single spaces, and trims. Returns "" when nothing meaningful remains.
public enum DictationTextCleanup {
    public static func clean(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DictationTextCleanup`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/WhisperCore/DictationTextCleanup.swift Tests/WhisperCoreTests/DictationTextCleanupTests.swift
git commit -m "feat: add DictationTextCleanup"
```

---

## Task 3: `DictationSession` state machine

**Files:**
- Create: `Sources/WhisperCore/DictationSession.swift`
- Test: `Tests/WhisperCoreTests/DictationSessionTests.swift`

**Interfaces:**
- Produces:
  - `enum DictationSession.State { idle, listening, transcribing, delivering, done, failed(FailureReason) }`
  - `enum DictationSession.FailureReason { emptyTranscript, engine(String) }`
  - `enum DictationSession.Event { startPressed, endPressed(clipDuration: TimeInterval), transcriptReady(String), delivered, engineFailed(String), dismiss }`
  - `enum DictationSession.Action { none, startCapture, discard, transcribe, deliver(String), busy, reset }`
  - `var DictationSession.state: State` (get), `mutating func handle(_ Event) -> Action`, `init(minClipDuration: TimeInterval = 0.35)`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/WhisperCoreTests/DictationSessionTests.swift
import Testing
@testable import WhisperCore

@Test("press starts capture; short clip is discarded; long clip transcribes")
func sessionCapturePaths() {
    var s = DictationSession(minClipDuration: 0.35)
    #expect(s.handle(.startPressed) == .startCapture)
    #expect(s.state == .listening)

    var short = DictationSession(minClipDuration: 0.35)
    _ = short.handle(.startPressed)
    #expect(short.handle(.endPressed(clipDuration: 0.1)) == .discard)
    #expect(short.state == .idle)

    #expect(s.handle(.endPressed(clipDuration: 1.0)) == .transcribe)
    #expect(s.state == .transcribing)
}

@Test("transcript delivers when non-empty and fails when empty")
func sessionTranscriptPaths() {
    var s = DictationSession()
    _ = s.handle(.startPressed); _ = s.handle(.endPressed(clipDuration: 1))
    #expect(s.handle(.transcriptReady("hi")) == .deliver("hi"))
    #expect(s.state == .delivering)
    #expect(s.handle(.delivered) == DictationSession.Action.none)
    #expect(s.state == .done)
    #expect(s.handle(.dismiss) == .reset)
    #expect(s.state == .idle)

    var empty = DictationSession()
    _ = empty.handle(.startPressed); _ = empty.handle(.endPressed(clipDuration: 1))
    #expect(empty.handle(.transcriptReady("")) == DictationSession.Action.none)
    #expect(empty.state == .failed(.emptyTranscript))
}

@Test("press while busy flashes busy; engine failure fails the session")
func sessionGuards() {
    var s = DictationSession()
    _ = s.handle(.startPressed)
    #expect(s.handle(.startPressed) == .busy)
    #expect(s.state == .listening)

    _ = s.handle(.endPressed(clipDuration: 1))
    #expect(s.handle(.engineFailed("boom")) == DictationSession.Action.none)
    #expect(s.state == .failed(.engine("boom")))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DictationSession`
Expected: FAIL — `cannot find 'DictationSession' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/WhisperCore/DictationSession.swift
import Foundation

/// Pure push-to-talk state machine. Given user/engine events it returns the next side-effecting
/// action for the controller to perform. No timers, no I/O — fully unit-testable.
public struct DictationSession: Sendable {
    public enum FailureReason: Equatable, Sendable {
        case emptyTranscript
        case engine(String)
    }

    public enum State: Equatable, Sendable {
        case idle, listening, transcribing, delivering, done
        case failed(FailureReason)
    }

    public enum Event: Sendable {
        case startPressed
        case endPressed(clipDuration: TimeInterval)
        case transcriptReady(String)
        case delivered
        case engineFailed(String)
        case dismiss
    }

    public enum Action: Equatable, Sendable {
        case none, startCapture, discard, transcribe, deliver(String), busy, reset
    }

    public private(set) var state: State = .idle
    public var minClipDuration: TimeInterval

    public init(minClipDuration: TimeInterval = 0.35) {
        self.minClipDuration = minClipDuration
    }

    public mutating func handle(_ event: Event) -> Action {
        switch (state, event) {
        case (.idle, .startPressed):
            state = .listening
            return .startCapture
        case (_, .startPressed):
            return .busy
        case let (.listening, .endPressed(duration)):
            if duration < minClipDuration {
                state = .idle
                return .discard
            }
            state = .transcribing
            return .transcribe
        case let (.transcribing, .transcriptReady(text)):
            if text.isEmpty {
                state = .failed(.emptyTranscript)
                return .none
            }
            state = .delivering
            return .deliver(text)
        case (.delivering, .delivered):
            state = .done
            return .none
        case let (_, .engineFailed(message)):
            state = .failed(.engine(message))
            return .none
        case (_, .dismiss):
            state = .idle
            return .reset
        default:
            return .none
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DictationSession`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/WhisperCore/DictationSession.swift Tests/WhisperCoreTests/DictationSessionTests.swift
git commit -m "feat: add DictationSession state machine"
```

---

## Task 4: `DictationProtocol` — wire types, framing, engine protocol, hotkey config

**Files:**
- Create: `Sources/WhisperCore/DictationProtocol.swift`
- Test: `Tests/WhisperCoreTests/DictationProtocolTests.swift`

**Interfaces:**
- Produces:
  - `struct DictationRequest: Codable, Equatable, Sendable { var wavPath: String; var language: String?; var initialPrompt: String? }`
  - `struct DictationResponse: Codable, Equatable, Sendable { var text: String?; var language: String?; var error: String? }`
  - `enum DictationWireProtocol { static func encodeLine<T: Encodable>(_:) throws -> Data; static func decodeResponse(line: Data) throws -> DictationResponse; static func takeLine(_ buffer: inout Data) -> Data? }`
  - `struct DictationResult: Sendable, Equatable { let text: String; let languageCode: String? }`
  - `protocol DictationEngine: Sendable { func transcribe(wavAt: URL, language: WhisperLanguage, initialPrompt: String?) async throws -> DictationResult; func warmUp() async throws; func shutdown() }`
  - `struct DictationHotkey: Codable, Equatable, Sendable { var keyCode: UInt16; var mode: Mode; enum Mode { hold, toggle }; static let rightOption }`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/WhisperCoreTests/DictationProtocolTests.swift
import Testing
import Foundation
@testable import WhisperCore

@Test("request round-trips through newline framing")
func requestRoundTrip() throws {
    let req = DictationRequest(wavPath: "/tmp/a.wav", language: "English", initialPrompt: nil)
    var buffer = try DictationWireProtocol.encodeLine(req)
    #expect(buffer.last == 0x0A)
    let line = DictationWireProtocol.takeLine(&buffer)
    #expect(line != nil)
    #expect(buffer.isEmpty)
    let decoded = try JSONDecoder().decode(DictationRequest.self, from: line!)
    #expect(decoded == req)
}

@Test("response decodes from a framed line")
func responseDecode() throws {
    let resp = DictationResponse(text: "hi", language: "en", error: nil)
    var buffer = try DictationWireProtocol.encodeLine(resp)
    let line = DictationWireProtocol.takeLine(&buffer)!
    #expect(try DictationWireProtocol.decodeResponse(line: line) == resp)
}

@Test("takeLine returns nil until a full line is present, then splits multiple")
func takeLinePartial() {
    var partial = Data("no newline yet".utf8)
    #expect(DictationWireProtocol.takeLine(&partial) == nil)
    var two = Data("first\nsecond\n".utf8)
    #expect(String(decoding: DictationWireProtocol.takeLine(&two)!, as: UTF8.self) == "first")
    #expect(String(decoding: DictationWireProtocol.takeLine(&two)!, as: UTF8.self) == "second")
    #expect(DictationWireProtocol.takeLine(&two) == nil)
}

@Test("rightOption hotkey default is keyCode 61 hold")
func hotkeyDefault() {
    #expect(DictationHotkey.rightOption == DictationHotkey(keyCode: 61, mode: .hold))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DictationProtocol`
Expected: FAIL — `cannot find 'DictationRequest' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/WhisperCore/DictationProtocol.swift
import Foundation

public struct DictationRequest: Codable, Equatable, Sendable {
    public var wavPath: String
    public var language: String?
    public var initialPrompt: String?
    public init(wavPath: String, language: String?, initialPrompt: String?) {
        self.wavPath = wavPath
        self.language = language
        self.initialPrompt = initialPrompt
    }
}

public struct DictationResponse: Codable, Equatable, Sendable {
    public var text: String?
    public var language: String?
    public var error: String?
    public init(text: String?, language: String?, error: String?) {
        self.text = text
        self.language = language
        self.error = error
    }
}

/// Newline-delimited JSON framing shared with `whisper_dictate_server.py`. `JSONEncoder` never emits
/// literal newlines, so one physical line is exactly one JSON message.
public enum DictationWireProtocol {
    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    public static func decodeResponse(line: Data) throws -> DictationResponse {
        try JSONDecoder().decode(DictationResponse.self, from: line)
    }

    /// Removes and returns the first complete `\n`-terminated line from `buffer`, or nil if none yet.
    public static func takeLine(_ buffer: inout Data) -> Data? {
        guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
        let line = buffer.subdata(in: buffer.startIndex..<newline)
        buffer.removeSubrange(buffer.startIndex...newline)
        return line
    }
}

public struct DictationResult: Sendable, Equatable {
    public let text: String
    public let languageCode: String?
    public init(text: String, languageCode: String?) {
        self.text = text
        self.languageCode = languageCode
    }
}

/// A source of transcripts for quick dictation. Implementations may hold a warm model.
public protocol DictationEngine: Sendable {
    func warmUp() async throws
    func transcribe(wavAt url: URL, language: WhisperLanguage, initialPrompt: String?) async throws -> DictationResult
    func shutdown()
}

public struct DictationHotkey: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case hold, toggle }
    public var keyCode: UInt16
    public var mode: Mode
    public init(keyCode: UInt16, mode: Mode) {
        self.keyCode = keyCode
        self.mode = mode
    }
    /// Right Option (kVK_RightOption = 0x3D = 61), hold-to-talk. The out-of-box default.
    public static let rightOption = DictationHotkey(keyCode: 61, mode: .hold)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DictationProtocol`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/WhisperCore/DictationProtocol.swift Tests/WhisperCoreTests/DictationProtocolTests.swift
git commit -m "feat: add dictation wire protocol, engine protocol, hotkey config"
```

---

## Task 5: `whisper_dictate_server.py` (warm helper) + runtime plumbing

**Files:**
- Create: `Scripts/whisper_dictate_server.py`
- Modify: `Sources/WhisperCore/LocalWhisperClient.swift` (add runtime helpers to `LocalWhisperRuntime`), `Sources/WhisperCore/TranscriptModels.swift:28` (`public var commandLineValue`)
- Modify: `Scripts/setup-local-whisper.sh`, `Scripts/build-app.sh`

**Interfaces:**
- Produces: `LocalWhisperRuntime.pythonExecutable(applicationSupport:) -> URL`, `LocalWhisperRuntime.dictationServerScript(applicationSupport:) -> URL`; `WhisperLanguage.commandLineValue` becomes `public`.
- Wire: reads `\n`-delimited `DictationRequest` JSON on stdin; on startup prints `{"ready": true}\n`; per request prints a `DictationResponse` JSON line.

- [ ] **Step 1: Write the helper script**

```python
# Scripts/whisper_dictate_server.py
"""Resident Whisper helper for WhisperMeet quick dictation.

Loads the model once, then serves newline-delimited JSON requests on stdin and
writes newline-delimited JSON responses on stdout. Local-only; no network.
Exits cleanly when stdin closes (the app terminates it to evict the model).
"""
import argparse
import json
import sys


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="turbo")
    parser.add_argument("--model-dir", required=True)
    args = parser.parse_args()

    import whisper  # imported after arg parse so --help is instant
    model = whisper.load_model(args.model, download_root=args.model_dir)

    # Signal readiness only after the model is resident.
    sys.stdout.write(json.dumps({"ready": True}) + "\n")
    sys.stdout.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
            result = model.transcribe(
                request["wavPath"],
                task="transcribe",
                language=request.get("language"),
                initial_prompt=request.get("initialPrompt"),
                fp16=False,
            )
            response = {"text": result.get("text", ""), "language": result.get("language")}
        except Exception as error:  # never crash the daemon on one bad request
            response = {"error": str(error)}
        sys.stdout.write(json.dumps(response) + "\n")
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Make `commandLineValue` public**

In `Sources/WhisperCore/TranscriptModels.swift:28`, change `var commandLineValue: String?` to `public var commandLineValue: String?`.

- [ ] **Step 3: Add runtime path helpers**

In `Sources/WhisperCore/LocalWhisperClient.swift`, inside `struct LocalWhisperRuntime`, add after `findExecutable` (line 66):

```swift
    public static func pythonExecutable(applicationSupport: URL? = nil) -> URL {
        managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("venv/bin/python")
    }

    public static func dictationServerScript(applicationSupport: URL? = nil) -> URL {
        managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("whisper_dictate_server.py")
    }
```

- [ ] **Step 4: Install the helper in setup + bundle it in build**

In `Scripts/setup-local-whisper.sh`, after line 28 (`… whisper --help >/dev/null`), add:

```bash
script_source="${0:A:h}/whisper_dictate_server.py"
if [[ -f "$script_source" ]]; then
  cp "$script_source" "$runtime_directory/whisper_dictate_server.py"
fi
```

In `Scripts/build-app.sh`, after line 21 (`chmod +x … setup-local-whisper.sh`), add:

```bash
cp "Scripts/whisper_dictate_server.py" "$app_dir/Contents/Resources/whisper_dictate_server.py"
```

(The bundled setup script copies both files out of `Contents/Resources` into the runtime dir on install; ensure `setup-local-whisper.sh`'s `${0:A:h}` resolves to `Contents/Resources` where the `.py` now sits.)

- [ ] **Step 5: Build + test (nothing broken)**

Run: `swift build && swift test --filter Dictation`
Expected: build succeeds; existing dictation tests still pass.

- [ ] **Step 6: Manual smoke test of the helper (requires installed runtime)**

Run:
```bash
PY="$HOME/Library/Application Support/WhisperMeet/Runtime/venv/bin/python"
MODELS="$HOME/Library/Application Support/WhisperMeet/Models"
printf '{"wavPath":"/System/Library/Sounds/Glass.aiff","language":null,"initialPrompt":null}\n' \
  | "$PY" Scripts/whisper_dictate_server.py --model turbo --model-dir "$MODELS"
```
Expected: a `{"ready": true}` line, then a `{"text": …, "language": …}` line (text may be empty for a non-speech sound). No crash.

- [ ] **Step 7: Commit**

```bash
git add Scripts/whisper_dictate_server.py Sources/WhisperCore/LocalWhisperClient.swift Sources/WhisperCore/TranscriptModels.swift Scripts/setup-local-whisper.sh Scripts/build-app.sh
git commit -m "feat: add warm Whisper dictation helper + runtime plumbing"
```

---

## Task 6: `WarmWhisperDictationEngine` + `BatchWhisperDictationEngine`

**Files:**
- Create: `Sources/WhisperCore/WarmWhisperDictationEngine.swift`

**Interfaces:**
- Consumes: `DictationEngine`, `DictationRequest/Response`, `DictationWireProtocol`, `WhisperLanguage.commandLineValue`, `LocalWhisperClient`, `LocalWhisperError`.
- Produces:
  - `final class WarmWhisperDictationEngine: DictationEngine` with `init(python: URL, script: URL, modelDirectory: URL, model: WhisperModel = .turbo)`
  - `struct BatchWhisperDictationEngine: DictationEngine` with `init(client: LocalWhisperClient, model: WhisperModel = .turbo)`

- [ ] **Step 1: Write the implementation**

```swift
// Sources/WhisperCore/WarmWhisperDictationEngine.swift
import Foundation

/// Keeps a Whisper model resident in a child Python process, driven over stdin/stdout
/// newline-delimited JSON, so repeat dictations skip the multi-second model-load cost.
/// All process/IO work is serialized on a private queue; the model is evicted on `shutdown()`.
public final class WarmWhisperDictationEngine: DictationEngine, @unchecked Sendable {
    private let python: URL
    private let script: URL
    private let modelDirectory: URL
    private let model: WhisperModel
    private let queue = DispatchQueue(label: "com.whispermeet.dictation.engine")

    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var stdoutBuffer = Data()

    public init(python: URL, script: URL, modelDirectory: URL, model: WhisperModel = .turbo) {
        self.python = python
        self.script = script
        self.modelDirectory = modelDirectory
        self.model = model
    }

    public func warmUp() async throws {
        try await run { try self.ensureRunning() }
    }

    public func transcribe(
        wavAt url: URL,
        language: WhisperLanguage,
        initialPrompt: String?
    ) async throws -> DictationResult {
        try await run {
            try self.ensureRunning()
            let request = DictationRequest(
                wavPath: url.path,
                language: language.commandLineValue,
                initialPrompt: initialPrompt
            )
            self.stdin?.write(try DictationWireProtocol.encodeLine(request))
            let line = try self.readLine(timeout: 120)
            let response = try DictationWireProtocol.decodeResponse(line: line)
            if let error = response.error {
                throw LocalWhisperError.processFailed(error)
            }
            let text = (response.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return DictationResult(text: text, languageCode: response.language)
        }
    }

    public func shutdown() {
        queue.sync {
            try? self.stdin?.close()
            self.process?.terminate()
            self.process = nil
            self.stdin = nil
            self.stdout = nil
            self.stdoutBuffer.removeAll()
        }
    }

    // MARK: - Serialized helpers (always run on `queue`)

    private func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func ensureRunning() throws {
        if let process, process.isRunning { return }
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw LocalWhisperError.runtimeNotInstalled
        }
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw LocalWhisperError.runtimeNotInstalled
        }
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = python
        process.arguments = [script.path, "--model", model.rawValue, "--model-dir", modelDirectory.path]
        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        try process.run()

        self.process = process
        self.stdin = inPipe.fileHandleForWriting
        self.stdout = outPipe.fileHandleForReading
        self.stdoutBuffer.removeAll()

        // Block until the helper reports the model is resident.
        let readyLine = try readLine(timeout: 180)
        guard
            let ready = try? JSONDecoder().decode([String: Bool].self, from: readyLine),
            ready["ready"] == true
        else {
            throw LocalWhisperError.processFailed("Dictation helper failed to start.")
        }
    }

    private func readLine(timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let line = DictationWireProtocol.takeLine(&stdoutBuffer) { return line }
            guard let stdout else { throw LocalWhisperError.processFailed("Dictation helper is not running.") }
            let chunk = stdout.availableData
            if chunk.isEmpty {
                throw LocalWhisperError.processFailed("Dictation helper stopped unexpectedly.")
            }
            stdoutBuffer.append(chunk)
            if Date() > deadline {
                throw LocalWhisperError.processFailed("Dictation helper timed out.")
            }
        }
    }
}

/// Cold fallback: one `whisper` CLI run per clip. No warm model — used only when the helper
/// cannot start. Reuses the existing, battle-tested `LocalWhisperClient`.
public struct BatchWhisperDictationEngine: DictationEngine {
    private let client: LocalWhisperClient
    private let model: WhisperModel

    public init(client: LocalWhisperClient, model: WhisperModel = .turbo) {
        self.client = client
        self.model = model
    }

    public func warmUp() async throws {}

    public func transcribe(
        wavAt url: URL,
        language: WhisperLanguage,
        initialPrompt: String?
    ) async throws -> DictationResult {
        let options = LocalTranscriptionOptions.accuracyFirst(
            model: model,
            language: language,
            keyterms: initialPrompt.map { [$0] } ?? []
        )
        let result = try await client.transcribe(recordingAt: url, options: options)
        return DictationResult(text: result.text, languageCode: result.languageCode)
    }

    public func shutdown() {}
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: build succeeds, no warnings.

- [ ] **Step 3: Manual integration smoke test (optional, requires installed runtime)**

This is exercised end-to-end in Task 14. No headless test — sockets/subprocess I/O aren't unit-testable in this project's convention (matches `WhisperMeet` having no tests).

- [ ] **Step 4: Commit**

```bash
git add Sources/WhisperCore/WarmWhisperDictationEngine.swift
git commit -m "feat: add warm + batch dictation engines"
```

---

## Task 7: `MicDictationRecorder`

**Files:**
- Create: `Sources/WhisperMeet/Dictation/MicDictationRecorder.swift`

**Interfaces:**
- Consumes: `WAVWriter`.
- Produces: `final class MicDictationRecorder` with `func requestPermission() async -> Bool`, `func start(onLevel: @escaping @Sendable (Float) -> Void) throws`, `func stop() throws -> (url: URL, duration: TimeInterval)`, `func cancel()`.

- [ ] **Step 1: Write the implementation**

```swift
// Sources/WhisperMeet/Dictation/MicDictationRecorder.swift
import AVFoundation
import WhisperCore

/// Mic-only capture for quick dictation. Uses AVAudioEngine (NOT ScreenCaptureKit) so dictation
/// never requires Screen Recording permission. Produces a 16 kHz mono WAV in the temp dir.
final class MicDictationRecorder: @unchecked Sendable {
    enum RecorderError: Error { case notRecording }

    private let engine = AVAudioEngine()
    private let targetSampleRate: Double = 16_000
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var onLevel: (@Sendable (Float) -> Void)?
    private(set) var isRecording = false

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(onLevel: @escaping @Sendable (Float) -> Void) throws {
        guard !isRecording else { return }
        samples.removeAll(keepingCapacity: true)
        self.onLevel = onLevel

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else { throw RecorderError.notRecording }
        converter = AVAudioConverter(from: inputFormat, to: outputFormat)

        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer, outputFormat: outputFormat)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    private func process(buffer: AVAudioPCMBuffer, outputFormat: AVAudioFormat) {
        guard let converter else { return }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0] else { return }

        let frames = Int(output.frameLength)
        guard frames > 0 else { return }
        var chunk = [Float](repeating: 0, count: frames)
        var sumOfSquares: Float = 0
        for index in 0..<frames {
            let value = channel[index]
            chunk[index] = value
            sumOfSquares += value * value
        }
        samples.append(contentsOf: chunk)
        let rms = (sumOfSquares / Float(frames)).squareRoot()
        let level = min(1, rms * 8)
        let handler = onLevel
        DispatchQueue.main.async { handler?(level) }
    }

    func stop() throws -> (url: URL, duration: TimeInterval) {
        guard isRecording else { throw RecorderError.notRecording }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        onLevel = nil

        let data = WAVWriter.wavData(from: samples, sampleRate: Int(targetSampleRate))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-\(UUID().uuidString).wav")
        try data.write(to: url)
        let duration = Double(samples.count) / targetSampleRate
        return (url, duration)
    }

    func cancel() {
        if isRecording {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRecording = false
        }
        onLevel = nil
        samples.removeAll()
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/WhisperMeet/Dictation/MicDictationRecorder.swift
git commit -m "feat: add mic-only dictation recorder (AVAudioEngine)"
```

---

## Task 8: `HotkeyMonitor`

**Files:**
- Create: `Sources/WhisperMeet/Dictation/HotkeyMonitor.swift`

**Interfaces:**
- Consumes: `DictationHotkey`.
- Produces: `final class HotkeyMonitor` with `var onPressStart: (() -> Void)?`, `var onPressEnd: (() -> Void)?`, `@discardableResult func start(hotkey: DictationHotkey) -> Bool`, `func stop()`, `static var isAccessibilityTrusted: Bool`, `static func requestAccessibility()`.

- [ ] **Step 1: Write the implementation**

```swift
// Sources/WhisperMeet/Dictation/HotkeyMonitor.swift
import AppKit
import ApplicationServices
import CoreGraphics
import WhisperCore

/// Global push-to-talk listener backed by a listen-only CGEventTap. Detects the configured key's
/// down/up (modifier keys via `.flagsChanged`, regular keys via `.keyDown`/`.keyUp`) and reports
/// press/release on the main queue. Requires Accessibility (the tap) — the same grant used for paste.
final class HotkeyMonitor {
    var onPressStart: (() -> Void)?
    var onPressEnd: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hotkey: DictationHotkey = .rightOption
    private var isKeyDown = false

    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @discardableResult
    func start(hotkey: DictationHotkey) -> Bool {
        stop()
        self.hotkey = hotkey
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo!).takeUnretainedValue()
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false // not trusted / Input Monitoring off
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        tap = nil
        runLoopSource = nil
        isKeyDown = false
    }

    private var flagMask: CGEventFlags {
        switch hotkey.keyCode {
        case 61, 58: return .maskAlternate   // right/left Option
        case 59, 62: return .maskControl     // left/right Control
        case 55, 54: return .maskCommand     // left/right Command
        case 56, 60: return .maskShift       // left/right Shift
        default: return .maskAlternate
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == hotkey.keyCode else { return }

        let pressed: Bool
        switch type {
        case .flagsChanged: pressed = event.flags.contains(flagMask)
        case .keyDown: pressed = true
        case .keyUp: pressed = false
        default: return
        }
        dispatch(pressed: pressed)
    }

    private func dispatch(pressed: Bool) {
        switch hotkey.mode {
        case .hold:
            if pressed, !isKeyDown {
                isKeyDown = true
                DispatchQueue.main.async { self.onPressStart?() }
            } else if !pressed, isKeyDown {
                isKeyDown = false
                DispatchQueue.main.async { self.onPressEnd?() }
            }
        case .toggle:
            guard pressed else { return } // act on key-down edge only
            isKeyDown.toggle()
            let starting = isKeyDown
            DispatchQueue.main.async {
                starting ? self.onPressStart?() : self.onPressEnd?()
            }
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/WhisperMeet/Dictation/HotkeyMonitor.swift
git commit -m "feat: add global push-to-talk HotkeyMonitor (CGEventTap)"
```

---

## Task 9: `TextInjector`

**Files:**
- Create: `Sources/WhisperMeet/Dictation/TextInjector.swift`

**Interfaces:**
- Produces: `enum TextInjector { enum Delivery { pasted, clipboard }; @discardableResult static func deliver(_ text: String) -> Delivery }`

- [ ] **Step 1: Write the implementation**

```swift
// Sources/WhisperMeet/Dictation/TextInjector.swift
import AppKit
import ApplicationServices
import CoreGraphics

/// Delivers dictated text: writes it to the clipboard and, when Accessibility is granted,
/// synthesizes ⌘V into the focused app. Otherwise leaves it on the clipboard for a manual paste.
enum TextInjector {
    enum Delivery { case pasted, clipboard }

    @discardableResult
    static func deliver(_ text: String) -> Delivery {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard AXIsProcessTrusted(),
              let source = CGEventSource(stateID: .combinedSessionState) else {
            return .clipboard
        }

        // Let the pasteboard settle before the synthetic paste.
        usleep(20_000)

        let vKey: CGKeyCode = 9 // kVK_ANSI_V
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
        return .pasted
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/WhisperMeet/Dictation/TextInjector.swift
git commit -m "feat: add TextInjector (clipboard + synthesized paste)"
```

---

## Task 10: `DictationOverlay` (floating pill)

**Files:**
- Create: `Sources/WhisperMeet/Dictation/DictationOverlay.swift`

**Interfaces:**
- Produces: `final class DictationOverlay` with `enum Phase { listening, transcribing, done, copied, empty, error, busy }`, `func show(_ phase: Phase)`, `func update(level: Float)`, `func hide()`.

- [ ] **Step 1: Write the implementation**

```swift
// Sources/WhisperMeet/Dictation/DictationOverlay.swift
import AppKit
import SwiftUI

/// A borderless, non-activating panel pinned near the bottom-center of the active screen. It never
/// becomes key, so it never steals focus from the app you are dictating into.
@MainActor
final class DictationOverlay {
    enum Phase: Equatable {
        case listening, transcribing, done, copied, empty, error, busy
    }

    private let model = PillModel()
    private var panel: NSPanel?

    func show(_ phase: Phase) {
        model.phase = phase
        ensurePanel()
        reposition()
        panel?.orderFrontRegardless()
    }

    func update(level: Float) {
        model.level = level
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let hosting = NSHostingView(rootView: DictationPill(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: 220, height: 56)
        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = hosting
        self.panel = panel
    }

    private func reposition() {
        guard let panel else { return }
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let size = panel.frame.size
        let origin = NSPoint(
            x: screen.midX - size.width / 2,
            y: screen.minY + 80
        )
        panel.setFrameOrigin(origin)
    }
}

private final class PillModel: ObservableObject {
    @Published var phase: DictationOverlay.Phase = .listening
    @Published var level: Float = 0
}

private struct DictationPill: View {
    @ObservedObject var model: PillModel

    var body: some View {
        HStack(spacing: 10) {
            icon
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 0)
            if model.phase == .listening {
                LevelBars(level: model.level)
            }
        }
        .padding(.horizontal, 16)
        .frame(width: 220, height: 44)
        .background(.black.opacity(0.82), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
    }

    @ViewBuilder private var icon: some View {
        switch model.phase {
        case .listening: Circle().fill(.red).frame(width: 10, height: 10)
        case .transcribing: ProgressView().controlSize(.small).tint(.white)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .copied: Image(systemName: "doc.on.clipboard").foregroundStyle(.white)
        case .empty: Image(systemName: "waveform.slash").foregroundStyle(.yellow)
        case .error: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .busy: Image(systemName: "hourglass").foregroundStyle(.white)
        }
    }

    private var label: String {
        switch model.phase {
        case .listening: "Listening…"
        case .transcribing: "Transcribing…"
        case .done: "Pasted"
        case .copied: "Copied to clipboard"
        case .empty: "Didn’t catch that"
        case .error: "Dictation failed"
        case .busy: "Busy…"
        }
    }
}

private struct LevelBars: View {
    let level: Float
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(barOpacity(index)))
                    .frame(width: 3, height: 6 + CGFloat(index) * 3)
            }
        }
    }
    private func barOpacity(_ index: Int) -> Double {
        Double(level) * 5 > Double(index) ? 0.95 : 0.25
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/WhisperMeet/Dictation/DictationOverlay.swift
git commit -m "feat: add floating dictation overlay pill"
```

---

## Task 11: `DictationController` (orchestrator)

**Files:**
- Create: `Sources/WhisperMeet/Dictation/DictationController.swift`

**Interfaces:**
- Consumes: everything above — `DictationSession`, `DictationEngine`/`WarmWhisperDictationEngine`/`BatchWhisperDictationEngine`, `DictationTextCleanup`, `DictationHotkey`, `MicDictationRecorder`, `HotkeyMonitor`, `TextInjector`, `DictationOverlay`, `LocalWhisperRuntime`, `LocalWhisperClient`, `WhisperLanguage`.
- Produces: `@MainActor final class DictationController: ObservableObject` with published `enabled`, `status`, `hotkey`, `language`, `autoPaste`; `func configure(isMeetingActive: @escaping () -> Bool)`, `func setEnabled(_ on: Bool)`, `func warmUpIfNeeded()`, `enum Status`.

- [ ] **Step 1: Write the implementation**

```swift
// Sources/WhisperMeet/Dictation/DictationController.swift
import AppKit
import Foundation
import UserNotifications
import WhisperCore
import os

/// Owns the quick-dictation feature end to end: hotkey → capture → warm Whisper → paste, driven by
/// the pure `DictationSession`. Independent of the meeting pipeline; disabled while a meeting records.
@MainActor
final class DictationController: ObservableObject {
    enum Status: Equatable {
        case disabled, idle, listening, transcribing, delivering
        case error(String)
    }

    @Published private(set) var status: Status = .disabled
    @Published var enabled: Bool { didSet { persist(); apply() } }
    @Published var hotkey: DictationHotkey { didSet { persist(); if enabled { _ = hotkeyMonitor.start(hotkey: hotkey) } } }
    @Published var language: WhisperLanguage { didSet { persist() } }
    @Published var autoPaste: Bool { didSet { persist() } }

    var isAccessibilityTrusted: Bool { HotkeyMonitor.isAccessibilityTrusted }
    func requestAccessibility() { HotkeyMonitor.requestAccessibility() }

    private let defaults: UserDefaults
    private let hotkeyMonitor = HotkeyMonitor()
    private let recorder = MicDictationRecorder()
    private let overlay = DictationOverlay()
    private let engine: DictationEngine
    private var session = DictationSession()
    private var isMeetingActive: () -> Bool = { false }
    private var dismissWorkItem: DispatchWorkItem?
    private let log = Logger(subsystem: "com.whispermeet.app", category: "dictation")

    private static let enabledKey = "dictationEnabled"
    private static let hotkeyKey = "dictationHotkey"
    private static let languageKey = "dictationLanguage"
    private static let autoPasteKey = "dictationAutoPaste"

    init(defaults: UserDefaults = .standard, engine: DictationEngine? = nil) {
        self.defaults = defaults
        self.engine = engine ?? DictationController.makeDefaultEngine()
        enabled = defaults.bool(forKey: Self.enabledKey)
        hotkey = (try? JSONDecoder().decode(DictationHotkey.self, from: defaults.data(forKey: Self.hotkeyKey) ?? Data())) ?? .rightOption
        language = WhisperLanguage(rawValue: defaults.string(forKey: Self.languageKey) ?? "") ?? .automatic
        autoPaste = defaults.object(forKey: Self.autoPasteKey) as? Bool ?? true

        hotkeyMonitor.onPressStart = { [weak self] in self?.handlePressStart() }
        hotkeyMonitor.onPressEnd = { [weak self] in self?.handlePressEnd() }
        apply()
    }

    private static func makeDefaultEngine() -> DictationEngine {
        let python = LocalWhisperRuntime.pythonExecutable()
        let script = LocalWhisperRuntime.dictationServerScript()
        let models = LocalWhisperRuntime.modelDirectory()
        return WarmWhisperDictationEngine(python: python, script: script, modelDirectory: models, model: .turbo)
    }

    func configure(isMeetingActive: @escaping () -> Bool) {
        self.isMeetingActive = isMeetingActive
    }

    func setEnabled(_ on: Bool) { enabled = on }

    func warmUpIfNeeded() {
        guard enabled else { return }
        Task.detached { [engine, log] in
            do { try await engine.warmUp() } catch { log.error("warm-up failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    // MARK: - Enable / disable

    private func apply() {
        if enabled {
            let started = hotkeyMonitor.start(hotkey: hotkey)
            status = .idle
            if !started {
                log.error("event tap could not be created — Accessibility/Input Monitoring off")
                status = .error("Enable Accessibility for WhisperMeet in System Settings.")
            }
            Task { await requestMicIfNeeded() }
            warmUpIfNeeded()
        } else {
            hotkeyMonitor.stop()
            overlay.hide()
            status = .disabled
        }
    }

    private func requestMicIfNeeded() async {
        _ = await recorder.requestPermission()
    }

    // MARK: - Hotkey events

    private func handlePressStart() {
        guard enabled else { return }
        if isMeetingActive() {
            log.notice("dictation press ignored — meeting recording active")
            flashBusy()
            return
        }
        switch session.handle(.startPressed) {
        case .startCapture: startCapture()
        case .busy: flashBusy()
        default: break
        }
    }

    private func handlePressEnd() {
        guard case .listening = statusMirror() else {
            // still handle to keep the machine honest
            _ = beginTranscriptionIfNeeded()
            return
        }
        _ = beginTranscriptionIfNeeded()
    }

    private func statusMirror() -> DictationSession.State { session.state }

    private func startCapture() {
        do {
            dismissWorkItem?.cancel()
            try recorder.start { [weak self] level in self?.overlay.update(level: level) }
            status = .listening
            overlay.show(.listening)
            log.notice("listening")
        } catch {
            _ = session.handle(.engineFailed(error.localizedDescription))
            fail(error.localizedDescription)
        }
    }

    private func beginTranscriptionIfNeeded() -> Bool {
        let clip: (url: URL, duration: TimeInterval)
        do { clip = try recorder.stop() }
        catch { return false }

        let action = session.handle(.endPressed(clipDuration: clip.duration))
        switch action {
        case .discard:
            try? FileManager.default.removeItem(at: clip.url)
            status = .idle
            overlay.hide()
            return true
        case .transcribe:
            status = .transcribing
            overlay.show(.transcribing)
            transcribe(clip: clip)
            return true
        default:
            try? FileManager.default.removeItem(at: clip.url)
            return false
        }
    }

    private func transcribe(clip: (url: URL, duration: TimeInterval)) {
        let language = self.language
        Task { [engine, log] in
            let started = Date()
            do {
                let result = try await engine.transcribe(wavAt: clip.url, language: language, initialPrompt: nil)
                try? FileManager.default.removeItem(at: clip.url)
                let cleaned = DictationTextCleanup.clean(result.text)
                log.notice("transcribed in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
                await MainActor.run { self.finish(text: cleaned) }
            } catch {
                try? FileManager.default.removeItem(at: clip.url)
                log.error("transcription failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    _ = self.session.handle(.engineFailed(error.localizedDescription))
                    self.fail(error.localizedDescription)
                }
            }
        }
    }

    private func finish(text: String) {
        switch session.handle(.transcriptReady(text)) {
        case let .deliver(payload):
            status = .delivering
            let delivery = autoPaste ? TextInjector.deliver(payload) : deliverClipboardOnly(payload)
            _ = session.handle(.delivered)
            switch delivery {
            case .pasted: overlay.show(.done)
            case .clipboard: overlay.show(.copied); notifyClipboard()
            }
            log.notice("delivered via \(delivery == .pasted ? "paste" : "clipboard", privacy: .public)")
            scheduleDismiss(after: 1.1)
        case .none where session.state == .failed(.emptyTranscript):
            overlay.show(.empty)
            scheduleDismiss(after: 1.3)
            status = .idle
        default:
            scheduleDismiss(after: 1.0)
            status = .idle
        }
    }

    private func deliverClipboardOnly(_ text: String) -> TextInjector.Delivery {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return .clipboard
    }

    private func flashBusy() {
        overlay.show(.busy)
        scheduleDismiss(after: 0.8)
    }

    private func fail(_ message: String) {
        status = .error(message)
        overlay.show(.error)
        scheduleDismiss(after: 1.6)
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        dismissWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.overlay.hide()
            _ = self?.session.handle(.dismiss)
            self?.status = .idle
        }
        dismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func notifyClipboard() {
        let content = UNMutableNotificationContent()
        content.title = "Dictation copied"
        content.body = "Transcript is on the clipboard — press ⌘V to paste."
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func persist() {
        defaults.set(enabled, forKey: Self.enabledKey)
        defaults.set(try? JSONEncoder().encode(hotkey), forKey: Self.hotkeyKey)
        defaults.set(language.rawValue, forKey: Self.languageKey)
        defaults.set(autoPaste, forKey: Self.autoPasteKey)
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: build succeeds. If the compiler flags the `.none where` pattern, replace that `case` with an explicit check: `case .none: if session.state == .failed(.emptyTranscript) { … } else { … }`.

- [ ] **Step 3: Commit**

```bash
git add Sources/WhisperMeet/Dictation/DictationController.swift
git commit -m "feat: add DictationController orchestrator"
```

---

## Task 12: Wire into the app — Package, AppModel guard, AppEntry menu bar + login

**Files:**
- Modify: `Package.swift:22-31`, `Sources/WhisperMeet/AppModel.swift`, `Sources/WhisperMeet/AppEntry.swift`

**Interfaces:**
- Consumes: `DictationController`.
- Produces: `AppModel.isRecordingActive: Bool`; `DictationController` created and wired in `AppEntry`; `MenuBarExtra` scene; launch-at-login via `SMAppService`.

- [ ] **Step 1: Add framework links**

In `Package.swift`, add to the `WhisperMeet` `linkerSettings` array (after line 31):

```swift
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications")
```

- [ ] **Step 2: Expose the meeting-active flag**

In `Sources/WhisperMeet/AppModel.swift`, add a computed property near `isRuntimeInstalled` (after line 140):

```swift
    var isRecordingActive: Bool {
        switch recordingState {
        case .idle: return false
        default: return true
        }
    }
```

- [ ] **Step 3: Create the controller and menu bar in AppEntry**

Replace `Sources/WhisperMeet/AppEntry.swift` with:

```swift
import SwiftUI
import ServiceManagement

@main
struct WhisperMeetApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var dictation = DictationController()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 620)
                .task {
                    dictation.configure(isMeetingActive: { [weak model] in model?.isRecordingActive ?? false })
                    await model.performStartupRecovery()
                }
        }
        .defaultSize(width: 1_100, height: 760)
        .windowToolbarStyle(.unified)

        MenuBarExtra("WhisperMeet Dictation", systemImage: menuBarSymbol) {
            DictationMenu(dictation: dictation)
        }

        Settings {
            SettingsView(model: model, dictation: dictation)
                .frame(width: 520)
                .padding(24)
        }
    }

    private var menuBarSymbol: String {
        switch dictation.status {
        case .listening: "mic.fill"
        case .transcribing, .delivering: "waveform"
        case .error: "mic.slash"
        default: "mic"
        }
    }
}

private struct DictationMenu: View {
    @ObservedObject var dictation: DictationController

    var body: some View {
        Toggle("Quick Dictation", isOn: Binding(
            get: { dictation.enabled },
            set: { dictation.setEnabled($0) }
        ))
        Divider()
        SettingsLink { Text("Settings…") }
        Button("Quit WhisperMeet") { NSApplication.shared.terminate(nil) }
    }
}
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: build succeeds. (`SettingsView` now takes a `dictation:` argument — added in Task 13; if building before Task 13, temporarily pass only `model:` and revisit. Prefer doing Task 12 + 13 together before building.)

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/WhisperMeet/AppModel.swift Sources/WhisperMeet/AppEntry.swift
git commit -m "feat: wire DictationController into app + menu bar"
```

---

## Task 13: Settings — "Quick Dictation" section + launch at login

**Files:**
- Modify: `Sources/WhisperMeet/ContentView.swift:723` (`SettingsView`)

**Interfaces:**
- Consumes: `DictationController`, `SMAppService`.
- Produces: `SettingsView(model:dictation:)`.

- [ ] **Step 1: Update `SettingsView` signature and add the section**

In `Sources/WhisperMeet/ContentView.swift`, change the `SettingsView` declaration (line 723-725) to:

```swift
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var dictation: DictationController
    @State private var apiKeyDraft = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
```

Add `import ServiceManagement` at the top of the file if not present. Then insert a new `Section` inside the `Form`, before the "Claude Summaries" section (before line 776):

```swift
            Section("Quick Dictation") {
                Toggle("Enable push-to-talk dictation", isOn: Binding(
                    get: { dictation.enabled },
                    set: { dictation.setEnabled($0) }
                ))
                Picker("Trigger mode", selection: Binding(
                    get: { dictation.hotkey.mode },
                    set: { dictation.hotkey = DictationHotkey(keyCode: dictation.hotkey.keyCode, mode: $0) }
                )) {
                    Text("Hold to talk").tag(DictationHotkey.Mode.hold)
                    Text("Toggle on/off").tag(DictationHotkey.Mode.toggle)
                }
                Picker("Language", selection: $dictation.language) {
                    ForEach(WhisperLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                Toggle("Paste into the focused field (else copy to clipboard)", isOn: $dictation.autoPaste)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            model.alertMessage = "Could not update launch-at-login: \(error.localizedDescription)"
                            launchAtLogin = (SMAppService.mainApp.status == .enabled)
                        }
                    }
                HStack {
                    Label(
                        dictation.isAccessibilityTrusted ? "Accessibility granted" : "Accessibility needed",
                        systemImage: dictation.isAccessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(dictation.isAccessibilityTrusted ? .green : .orange)
                    Spacer()
                    if !dictation.isAccessibilityTrusted {
                        Button("Grant…") { dictation.requestAccessibility() }
                    }
                }
                Text("Hold Right Option anywhere to dictate. Transcription is 100% local (Whisper turbo). Accessibility is required to paste and to detect the hold key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
```

- [ ] **Step 2: Update the inline settings call site**

Find where `SettingsView(model:)` is rendered inline for the `.settings` sidebar case (`ContentView.swift:137`) and update it to pass `dictation`. Because `ContentView` doesn't currently hold a `DictationController`, add a parameter to `ContentView` (`@ObservedObject var dictation: DictationController`) and thread it from `AppEntry` (`ContentView(model: model, dictation: dictation)`), and pass it to the inline `SettingsView(model: model, dictation: dictation)`.

Run: `grep -n "SettingsView(model:\|ContentView(model:" Sources/WhisperMeet/*.swift`
Expected after edits: every `SettingsView(...)` passes `dictation:`, and `ContentView(...)` passes `dictation:`.

- [ ] **Step 3: Build**

Run: `swift build`
Expected: build succeeds, no warnings.

- [ ] **Step 4: Full test suite**

Run: `swift test`
Expected: PASS — all prior tests plus the new WhisperCore dictation tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/WhisperMeet/ContentView.swift
git commit -m "feat: add Quick Dictation settings section + launch at login"
```

---

## Task 14: End-to-end verification, package, deploy, changelog

**Files:**
- Modify: `docs/CHANGELOG.md`

- [ ] **Step 1: Quality gate**

Run: `Scripts/quality-check.sh`
Expected: diff validation, full test suite, warnings-as-errors release build, packaging, signing all pass.

- [ ] **Step 2: Deploy the app**

Run: `Scripts/build-app.sh && Scripts/install-app.sh` (or `open .build/WhisperMeet.app`)
Expected: `/Applications/WhisperMeet.app` updated (installer refuses if a recording is active).

- [ ] **Step 3: Manual verification checklist**

Grant Microphone + Accessibility when prompted, then verify:
1. Close the main window — the menu-bar mic icon remains; app still running.
2. In TextEdit: hold Right Option, speak, release → text pastes into the field within ~1 s (after first warm-up).
3. Revoke Accessibility (or focus a non-editable spot) → text lands on the clipboard + a notification appears.
4. Speak Mandarin → Mandarin text, not translated.
5. Tap the key without speaking → nothing pastes; pill dismisses.
6. Start a meeting recording → dictation press shows "Busy…" and does nothing; stop the meeting → dictation works again.
7. Toggle Launch at login → confirm `SMAppService.mainApp.status == .enabled`.
8. Confirm NO Screen Recording prompt ever appears for dictation.

- [ ] **Step 4: Log the round in the changelog**

Append to `docs/CHANGELOG.md`:

```markdown
## Round 6 — Quick Dictation (push-to-talk, any app)
- New always-on push-to-talk dictation, separate from the meeting recorder: hold Right Option
  anywhere → speak → release → local Whisper (turbo) transcribes → auto-paste into the focused
  field (clipboard + notification fallback). Menu-bar presence + launch-at-login.
- Near-instant repeat dictations via a resident "warm" Whisper helper
  (`whisper_dictate_server.py`) that holds the model in RAM and serves clips over stdin/stdout.
- Mic-only AVAudioEngine capture — dictation never needs Screen Recording permission.
- New tested WhisperCore modules: `WAVWriter` (now the single WAV path, shared with the meeting
  mixer), `DictationSession`, `DictationTextCleanup`, `DictationProtocol`.
- New WhisperMeet framework units: `HotkeyMonitor` (CGEventTap), `MicDictationRecorder`,
  `TextInjector`, `DictationOverlay`, `DictationController`.
- Guards: dictation and meeting recording never contend for the mic; local-only preserved;
  original-language transcribe only.
```

- [ ] **Step 5: Commit**

```bash
git add docs/CHANGELOG.md
git commit -m "docs: log Round 6 — Quick Dictation"
```

---

## Self-review (against the spec)

**Spec coverage:** engine=warm helper (Tasks 5, 6) ✓; push-to-talk Right Option hold/toggle (Tasks 4, 8) ✓; overlay pill (Task 10) ✓; auto-paste + clipboard fallback + notification (Tasks 9, 11) ✓; menu bar + launch at login (Tasks 12, 13) ✓; mic-only no-Screen-Recording (Task 7) ✓; mic-contention guard (Tasks 11, 12) ✓; WAVWriter extraction + reuse (Task 1) ✓; language auto/EN/中文 (Tasks 5, 13) ✓; logging + changelog (Tasks 11, 14) ✓; permissions/Accessibility handling (Tasks 8, 11, 13) ✓; tests for pure units (Tasks 1-4) ✓; build/quality gate + deploy (Task 14) ✓.

**Deferred items correctly omitted:** AI cleanup, streaming words, dictation history, multiple profiles, clipboard-restore, auto-type mode — none appear as tasks. Optional vocabulary-as-`initial_prompt` is left as `initialPrompt: nil` at the call site (wiring exists in the engine/protocol for a later toggle); acceptable per "nearly free future add".

**Type consistency:** `DictationEngine` (`warmUp`/`transcribe`/`shutdown`) matches its two implementations and the controller's use. `DictationSession.Action`/`State`/`Event` names match across Task 3 and Task 11. `DictationHotkey(keyCode:mode:)` and `.rightOption` consistent across Tasks 4, 8, 11, 13. `WAVWriter.header/pcm16Data/wavData` consistent across Tasks 1 and 7. `LocalWhisperRuntime.pythonExecutable/dictationServerScript/modelDirectory` consistent across Tasks 5, 11.

**Known build-order note:** Tasks 12 and 13 change the same call sites (`SettingsView`/`ContentView` signatures); implement both before running the Task 12 build, or use the temporary single-arg shim noted in Task 12 Step 4.
