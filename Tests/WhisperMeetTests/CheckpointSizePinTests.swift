import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

// F900 (review finding c) — `LocalWhisperRuntime.checkpointByteCount` holds the sizes of the two
// openai-whisper checkpoints its `_MODELS` URLs named in the release the installer pins. A URL names
// its file's SHA-256, so the file behind it never changes; but a pin bump can point `turbo` at a new
// URL, and the hardcoded size would then read every whole checkpoint as not ready — the Intel model
// row saying "downloads on first dictation" for good, with nothing to flag it. So the sizes carry
// the version they were measured for, and this fails the moment the installer's pin moves.

/// The `openai_whisper_version="…"` assignments in `setup-local-whisper.sh`.
private func installerOpenAIWhisperPins() throws -> [String] {
    let installer = try String(contentsOf: SourceAssertion.url("Scripts/setup-local-whisper.sh"), encoding: .utf8)
    let prefix = "openai_whisper_version=\""
    return installer.split(separator: "\n").compactMap { line -> String? in
        guard line.hasPrefix(prefix), line.hasSuffix("\"") else { return nil }
        return String(line.dropFirst(prefix.count).dropLast())
    }
}

@Test("The checkpoint sizes were measured for the openai-whisper the installer pins (F900 review)")
func checkpointSizesFollowTheOpenAIWhisperPin() throws {
    let pins = try installerOpenAIWhisperPins()
    try #require(pins.count == 1, "expected one openai_whisper_version= line in setup-local-whisper.sh, found \(pins)")
    #expect(
        pins[0] == LocalWhisperRuntime.checkpointSizesOpenAIWhisperVersion,
        """
        setup-local-whisper.sh now pins openai-whisper \(pins[0]), but checkpointByteCount was measured for \
        \(LocalWhisperRuntime.checkpointSizesOpenAIWhisperVersion). Re-measure before changing the version: \
        read the turbo and large-v3 URLs in the new release's whisper/__init__.py `_MODELS`, take each one's \
        Content-Length (a HEAD, no download), update checkpointByteCount, then checkpointSizesOpenAIWhisperVersion.
        """
    )
}
