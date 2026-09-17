import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F285 — F33 (Qwen), F219 (speaker analysis) and F167 (local summarizer) each added a launch-time
// reclaim for an interrupted install, and the three were the same ~60 lines three times, differing
// in two hidden-directory prefixes, an environment-variable name and a bundled-script resource
// name.
//
// Low severity, but it is the shape that produced F278's duplicated WAV header and F282's two
// manifest types — and two instances were already visible: `spawnXInstallRecovery` returned `-1`
// ambiguously in all three, and **none of them tested that recovery-only mode skips the installer's
// preconditions**, which is the property that makes a reclaim work on a Mac without Homebrew. One
// reading that matters, unasserted in triplicate.
//
// F285's own verification is that the three existing reclaim test files pass **unchanged** — any of
// them needing an edit means the behaviour moved rather than the duplication. These two are the
// additions: the descriptor is right, and the property is finally asserted once.

@Test("Each runtime's reclaim descriptor names its own artifacts, script and switch (F285)")
func descriptorsAreDistinctAndComplete() {
    let all = [InstallReclaim.qwen, .summarizer, .diarization]

    // Distinct on every axis, because a copy-paste that left one field behind is precisely how
    // three near-identical functions drift — and a reclaim pointed at the wrong runtime would
    // restore the wrong backup.
    #expect(Set(all.map(\.artifactPrefix)).count == 3)
    #expect(Set(all.map(\.recoveryEnvironmentKey)).count == 3)
    #expect(Set(all.map(\.scriptResource)).count == 3)

    #expect(InstallReclaim.qwen.backupPrefix == ".Qwen3ASR-backup-")
    #expect(InstallReclaim.qwen.stagingPrefix == ".Qwen3ASR-install-")
    #expect(InstallReclaim.summarizer.backupPrefix == ".Summarizer-backup-")
    #expect(InstallReclaim.diarization.stagingPrefix == ".Diarization-install-")

    // The switches the installers actually read. A typo here is silent: the script would run its
    // full install path instead of reclaiming, on a Mac that may not meet the preconditions.
    #expect(InstallReclaim.qwen.recoveryEnvironmentKey == "QWEN_INSTALL_RECOVERY_ONLY")
    #expect(InstallReclaim.summarizer.recoveryEnvironmentKey == "SUMMARIZER_INSTALL_RECOVERY_ONLY")
    #expect(InstallReclaim.diarization.recoveryEnvironmentKey == "DIARIZATION_INSTALL_RECOVERY_ONLY")
}

@Test("Every installer's recovery-only switch short-circuits before its preconditions (F285)")
func recoveryOnlyModeSkipsThePreconditions() throws {
    // The property none of the three suites asserted, and the one that makes a reclaim work at all.
    // A Mac recovering an interrupted install already HAS the model — so if the script demanded
    // Homebrew, free space, or a bundled helper first, the reclaim would fail on exactly the
    // machines that need it. Each script therefore exits inside its recovery branch BEFORE the
    // first precondition.
    //
    // Asserted against the scripts' source rather than by running them: running one requires the
    // runtime, and this is a question about ORDER, which the source answers exactly.
    let scripts = [
        ("setup-qwen-asr.sh", "QWEN_INSTALL_RECOVERY_ONLY"),
        ("setup-local-summarizer.sh", "SUMMARIZER_INSTALL_RECOVERY_ONLY"),
        ("setup-speaker-diarization.sh", "DIARIZATION_INSTALL_RECOVERY_ONLY"),
    ]
    // Anything that would refuse to proceed on a machine that is merely recovering.
    let preconditions = ["brew", "available_kib", "8388608", "Homebrew"]

    for (name, key) in scripts {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Scripts/\(name)")
        // Comments stripped before scanning. Without this the test matched the word "Homebrew"
        // inside the comment that EXPLAINS why the exit precedes the preconditions — a false
        // positive that looked exactly like the defect. Checked before touching the scripts.
        //
        // Line-leading `#` only, deliberately: a trailing `#` can sit inside a quoted string or a
        // parameter expansion, and stripping those would corrupt the offsets this test compares.
        let source = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") ? "" : String($0) }
            .joined(separator: "\n")

        // Built with `NSRegularExpression`-style escaping rather than a raw literal with
        // interpolation, which Swift's `#"…\#(key)…"#` makes awkward inside a `#require` comment.
        let pattern = key + #"[^\n]*==[^\n]*"1"[\s\S]{0,80}?exit 0"#
        let branch = source.range(of: pattern, options: .regularExpression)
        #expect(branch != nil, "\(name) has no recovery-only branch that exits")
        guard let branch else { continue }
        let exitOffset = source.distance(from: source.startIndex, to: branch.upperBound)

        for precondition in preconditions {
            guard let found = source.range(of: precondition) else { continue }
            let offset = source.distance(from: source.startIndex, to: found.lowerBound)
            // One interpolated literal, not a concatenation: `Comment` is
            // `ExpressibleByStringInterpolation`, and `a + b` is a `String` expression rather than
            // a literal, so it will not convert.
            #expect(offset > exitOffset, "\(name): '\(precondition)' is checked BEFORE the recovery-only exit, so a reclaim would fail on a Mac that does not meet it")
        }
    }
}
