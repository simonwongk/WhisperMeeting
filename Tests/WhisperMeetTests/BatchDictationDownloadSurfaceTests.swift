import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

// F860 — on a Mac without the warm helper (Intel) the batch engine's first dictation downloads
// openai-whisper's turbo checkpoint (about 1.6 GB), silently, under "Transcribing…". Driven here as
// the app builds it there (`DictationController.makeEngine`): a `FallbackDictationEngine` whose warm
// helper cannot run, falling back to a real `BatchWhisperDictationEngine` over a stub `whisper`
// executable that prints openai-whisper's own download bar. This Mac is Apple silicon; that is the
// Intel path with its one Mac-specific part, the warm helper failing, stood in for.

/// The warm helper on a Mac that cannot run it: its warm-up fails as an MLX import failure does.
private struct CannotRunHereEngine: DictationEngine {
    func warmUp() async throws { throw LocalWhisperError.processFailed("No module named 'mlx'") }
    func transcribe(wavAt url: URL, language: WhisperLanguage, initialPrompt: String?) async throws -> DictationResult {
        throw LocalWhisperError.processFailed("No module named 'mlx'")
    }
    func shutdown() {}
}

@MainActor
@Test("On a Mac without the warm helper, the first dictation's checkpoint download shows in the pill and the tab, then the dictation is delivered (F860)")
func theBatchEnginesCheckpointDownloadIsShownThenTheDictationIsDelivered() async throws {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("F860-whisper-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let go = scratch.appendingPathComponent("go")
    let whisper = scratch.appendingPathComponent("whisper")
    // openai-whisper's own download bar (`unit="iB"`), held until the test has seen it, then the
    // transcription bar and the JSON the client reads.
    try """
    #!/bin/sh
    input="$1"; shift
    out=""
    while [ $# -gt 0 ]; do
      if [ "$1" = "--output_dir" ]; then out="$2"; shift; fi
      shift
    done
    name=$(basename "$input"); name="${name%.*}"
    printf ' 42%%|####2     | 650M/1.51G [00:05<00:07, 120MiB/s]\\r' >&2
    i=0; while [ -d "\(scratch.path)" ] && [ ! -e "\(go.path)" ] && [ $i -lt 1200 ]; do i=$((i+1)); sleep 0.05; done
    printf ' 50%%|#####     | 100/200 [00:01<00:01, 100.00frames/s]\\r' >&2
    printf '%s' '{"text": " Hello from the batch engine.", "language": "en", "segments": [{"start": 0.0, "end": 1.0, "text": " Hello from the batch engine.", "no_speech_prob": 0.01}]}' > "$out/$name.json"
    """.write(to: whisper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: whisper.path)
    let batch = BatchWhisperDictationEngine(
        client: LocalWhisperClient(executableURL: whisper, modelDirectory: scratch.appendingPathComponent("models")),
        model: .turbo
    )
    let rig = try DownloadSurfaceRig(engine: FallbackDictationEngine(primary: CannotRunHereEngine(), fallback: batch))
    defer { try? Data().write(to: go); rig.cleanUp() }

    rig.monitor.onPressStart?()
    try #require(rig.controller.status == .listening)
    rig.monitor.onPressEnd?()
    try await rig.waitUntil("the pill to show the download") {
        rig.overlay.phases.contains(.modelDownloading)
    }
    #expect(rig.controller.isDownloadingModel, "the Dictation tab and the menu bar read this")
    try await rig.waitUntil("the figure") { rig.controller.modelDownloadProgress?.percent == 42 }
    #expect(rig.controller.modelDownloadNoticeText.contains("42 %"))

    try Data().write(to: go)
    try await rig.waitUntil("the dictation to be delivered") {
        !rig.controller.logStore.log.entries.isEmpty
    }
    #expect(rig.controller.logStore.log.entries.first?.text.contains("batch engine") == true,
            "\(String(describing: rig.controller.logStore.log.entries.first))")
    #expect(!rig.controller.isDownloadingModel)
    let phases = rig.overlay.phases
    let downloading = try #require(phases.firstIndex(of: .modelDownloading))
    let backToTranscribing = try #require(phases.lastIndex(of: .transcribing))
    #expect(downloading < backToTranscribing, "\(phases)")
}
