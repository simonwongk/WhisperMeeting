import Foundation
import Testing

// F183 — script-shape tests. The install ordering and the best-effort guard are correctness
// requirements that only manifest on a real install, so they are asserted against the script text
// (the WhisperHelperScriptTests precedent of testing a helper script without running it).

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // WhisperCoreTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // repo root
}

private func scriptText(_ relativePath: String) throws -> String {
    try String(contentsOf: repositoryRoot().appendingPathComponent(relativePath), encoding: .utf8)
}

/// The script with its `#` comment lines removed (F384).
///
/// The assertions below are about ORDER — "yt-dlp is installed after Whisper is verified" — and
/// order is decided by the first occurrence of each needle. A comment added above the real command
/// that happens to quote it moves that occurrence and the ordering assertion silently changes
/// meaning. Nothing in `setup-local-whisper.sh` does that today (checked: every needle's first hit
/// is code), so this is prevention, not a repair.
///
/// Full-line only, like `installerCode` in `DiarizationInstallerScriptShapeTests`. A general shell
/// stripper would have to understand quoting and heredocs, and F384 measured the demand for one at
/// zero live defects across six files — so this is the small version, next to the one caller that
/// needs it.
private func scriptCode(_ relativePath: String) throws -> String {
    try scriptText(relativePath)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        .joined(separator: "\n")
}

@Test("yt-dlp installs after Whisper is verified and before the shebang rewrite (F183)")
func ytDlpInstallOrdering() throws {
    let text = try scriptCode("Scripts/setup-local-whisper.sh")
    let whisperVerified = try #require(text.range(of: #"bin/whisper" --help"#))
    let ytDlpInstall = try #require(text.range(of: "pip install --upgrade yt-dlp"))
    // The venv path rewrite that must come last, or bin/yt-dlp keeps a dead staging shebang.
    let shebangRewrite = try #require(text.range(of: "bindir = os.path.join"))

    #expect(whisperVerified.upperBound < ytDlpInstall.lowerBound,
            "yt-dlp must not be installed before the mandatory Whisper install is verified")
    #expect(ytDlpInstall.upperBound < shebangRewrite.lowerBound,
            "yt-dlp must be installed before the shebang rewrite, or its console script is dead after the swap")
}

@Test("The yt-dlp install is best-effort so a PyPI blip can't abort the runtime install (F183)")
func ytDlpInstallIsBestEffort() throws {
    let text = try scriptCode("Scripts/setup-local-whisper.sh")
    // `set -e` is in force, so the install must sit inside an `if !` condition to stay non-fatal.
    #expect(text.contains("if ! \"$staging_venv/bin/python\" -m pip install --upgrade yt-dlp; then"))
}

@Test("Runtime health checks do NOT require yt-dlp, so existing installs stay valid (F183)")
func healthChecksIgnoreYtDlp() throws {
    let text = try scriptCode("Scripts/setup-local-whisper.sh")
    // Requiring yt-dlp here would make every already-working install look broken and roll back to a
    // backup that also lacks it.
    let completeCheck = try #require(text.range(of: "venv_is_complete() {"))
    let worksCheckEnd = try #require(text.range(of: "cleanup_and_restore() {"))
    let healthSection = String(text[completeCheck.lowerBound..<worksCheckEnd.lowerBound])
    #expect(!healthSection.contains("yt-dlp"))
}

@Test("build-app.sh bundles update-yt-dlp.sh into the packaged app (F183)")
func updateScriptIsBundled() throws {
    // Nothing else exercises Bundle.main resource lookup, so a forgotten copy line here would pass
    // the whole test suite and only fail inside the packaged .app.
    let text = try scriptText("Scripts/build-app.sh")
    #expect(text.contains("update-yt-dlp.sh"))
    let updater = repositoryRoot().appendingPathComponent("Scripts/update-yt-dlp.sh")
    #expect(FileManager.default.fileExists(atPath: updater.path))
}
