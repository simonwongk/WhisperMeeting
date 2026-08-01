import Foundation
import Testing
@testable import WhisperCore

// F132 — the Qwen helper subprocess must be able to find Homebrew's ffmpeg. A GUI-launched app
// inherits a bare PATH (no /opt/homebrew/bin), so mlx-audio's `shutil.which("ffmpeg")`
// (`audio_io.py:67`) returns nil and imported .m4a/.aac recordings fail with "ffmpeg not found"
// though ffmpeg is installed. The environment the client hands the subprocess must therefore prepend
// Homebrew's bin dirs, matching LocalWhisperClient / WarmWhisperDictationEngine.

@Test("Qwen subprocess environment prepends Homebrew bin dirs to a bare GUI PATH")
func qwenSubprocessEnvironmentPrependsHomebrewToPath() {
    let env = QwenASRClient.makeEnvironment(base: ["PATH": "/usr/bin:/bin"])
    #expect(env["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
}

@Test("Qwen subprocess environment still exposes Homebrew bin dirs when PATH is unset")
func qwenSubprocessEnvironmentHandlesMissingPath() {
    let env = QwenASRClient.makeEnvironment(base: [:])
    let path = env["PATH"] ?? ""
    #expect(path.contains("/opt/homebrew/bin"))
    #expect(path.contains("/usr/local/bin"))
}

@Test("Qwen subprocess environment keeps the offline pins alongside the PATH fix")
func qwenSubprocessEnvironmentKeepsOfflinePins() {
    let env = QwenASRClient.makeEnvironment(base: ["PATH": "/usr/bin:/bin"])
    #expect(env["HF_HUB_OFFLINE"] == "1")
    #expect(env["TRANSFORMERS_OFFLINE"] == "1")
}
