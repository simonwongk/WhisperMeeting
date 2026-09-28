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
        // F520: the fourth reclaim.
        ("setup-local-whisper.sh", "WHISPER_INSTALL_RECOVERY_ONLY"),
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

// F439 part 3 — the test above caught only the LATE preconditions (Homebrew, storage), which are
// safe by simple position: they sit textually after the recovery-only branch's `exit 0`, so a
// recovery-only run never reaches them at all. It had no hand-written token for the EARLY
// preconditions — the architecture check and the three bundled-helper checks in
// setup-local-summarizer.sh — which are protected a different way: by being wrapped in their own
// `if [[ "${KEY:-0}" != "1" ]]` guard (as setup-qwen-asr.sh and setup-speaker-diarization.sh
// already do). setup-local-summarizer.sh had no such wrapper, so its `exit 1`s ran unconditionally,
// and no hand-picked keyword would have caught that shape of gap either — a keyword list can only
// be wrong by omission, in either direction.
//
// This derives the check instead: every `exit 1` that sits inside SOME `if`-block anywhere in the
// script (skipping ones that do not — the model-name `case` statement's `exit 1` is not gated by
// recovery mode at all, and is not supposed to be) must have at least one ENCLOSING `if`, at any
// nesting depth, whose own condition mentions the recovery-only key — whether that is the
// immediate if (an inline composite condition) or an outer wrapper if (Qwen's shape). A future
// early-exit precondition is caught automatically, without anyone maintaining a token list.

/// One `if [[ … ]]; then … fi` block found anywhere in `source`: its condition text (between `if`
/// and the next `then`) and the character range from the `if` keyword to the matching `fi`,
/// computed by depth-counting so a nested `if`/`fi` pair is skipped rather than mismatched.
private struct ShellIfBlock {
    let condition: Substring
    let range: Range<String.Index>
}

private func shellIfBlocks(in source: String) -> [ShellIfBlock] {
    let keywordPattern = #"\b(if|fi)\b"#
    guard let regex = try? NSRegularExpression(pattern: keywordPattern) else { return [] }
    let nsrange = NSRange(source.startIndex..<source.endIndex, in: source)
    let matches = regex.matches(in: source, range: nsrange).compactMap { match -> (String, Range<String.Index>)? in
        guard let range = Range(match.range, in: source) else { return nil }
        return (String(source[range]), range)
    }

    var blocks: [ShellIfBlock] = []
    var openIfStarts: [String.Index] = []   // stack of `if` keyword starts awaiting a `fi`
    for (keyword, range) in matches {
        if keyword == "if" {
            openIfStarts.append(range.lowerBound)
        } else { // "fi"
            guard let ifStart = openIfStarts.popLast() else { continue } // unmatched `fi`; ignore
            let conditionStart = source.index(ifStart, offsetBy: 2) // past "if"
            let conditionEnd = source.range(of: "then", range: conditionStart..<range.lowerBound)?.lowerBound
                ?? range.lowerBound
            blocks.append(ShellIfBlock(
                condition: source[conditionStart..<conditionEnd],
                range: ifStart..<range.upperBound
            ))
        }
    }
    return blocks
}

@Test("Every early exit 1 in the summarizer/Qwen/diarization installers is gated by their recovery-only switch (F439)")
func everyEarlyExitIsGatedByRecoveryOnlyMode() throws {
    let scripts = [
        ("setup-qwen-asr.sh", "QWEN_INSTALL_RECOVERY_ONLY"),
        ("setup-local-summarizer.sh", "SUMMARIZER_INSTALL_RECOVERY_ONLY"),
        ("setup-speaker-diarization.sh", "DIARIZATION_INSTALL_RECOVERY_ONLY"),
    ]

    for (name, key) in scripts {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Scripts/\(name)")
        let source = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") ? "" : String($0) }
            .joined(separator: "\n")

        let reclaimPattern = key + #"[^\n]*==[^\n]*"1"[\s\S]{0,80}?exit 0"#
        guard let reclaimBranch = source.range(of: reclaimPattern, options: .regularExpression) else {
            Issue.record("\(name) has no recovery-only branch that exits")
            continue
        }

        let blocks = shellIfBlocks(in: source)
        var earlyExitsChecked = 0
        var searchFrom = source.startIndex
        while let exitRange = source.range(of: "exit 1", range: searchFrom..<source.endIndex) {
            searchFrom = exitRange.upperBound
            guard exitRange.lowerBound < reclaimBranch.lowerBound else { continue } // a LATE exit 1
            let containing = blocks.filter { $0.range.contains(exitRange.lowerBound) }
            guard !containing.isEmpty else { continue } // not inside any `if` — e.g. a `case` arm
            // The cross-process lock probe (`shlock`) is deliberately NOT bypassed in recovery
            // mode, identically in all three scripts: two reclaims racing over the same runtime
            // directory is exactly the failure the lock exists to prevent, so "another install is
            // already running" must still refuse during a reclaim too. Not the shape this ticket
            // is about.
            guard !containing.contains(where: { $0.condition.contains("shlock") }) else { continue }
            earlyExitsChecked += 1
            let lineNumber = source[..<exitRange.lowerBound].filter { $0 == "\n" }.count + 1
            #expect(
                containing.contains { $0.condition.contains(key) },
                """
                \(name):\(lineNumber): this `exit 1` sits before the recovery-only branch and \
                inside an `if` (or nested `if`s), none of which mention \(key) — so it runs even \
                during a launch-time reclaim of an interrupted install, exactly the bundled-helper \
                gap this ticket closed for setup-local-summarizer.sh
                """
            )
        }
        // setup-local-summarizer.sh has four (arch + 3 helpers); the other two scripts have their
        // own. If this ever finds none, the derivation itself has stopped matching something.
        #expect(earlyExitsChecked > 0, "\(name): found no early, if-guarded `exit 1` at all — did the shape change?")
    }
}
