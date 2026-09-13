import Foundation
import Testing

// F219 — the speaker-analysis installer downloads 51 MB from the public internet, so its happy path
// cannot be exercised here. Every invariant that keeps a *bad* download from becoming the activated
// runtime is nonetheless checkable without a network, and those are the invariants that matter:
//
//   * a gate that runs after the swap is not a gate, so the ordering of every hash check, the GPL
//     licence check, and the offline check against the single atomic activation `mv` is asserted by
//     byte offset in the script text (the `LinkImportScriptShapeTests` precedent);
//   * the pinned hashes are the entire integrity story, so they are parsed out of the script and
//     compared against the pins table in `docs/DIARIZATION_RUNTIME_DECISION.md` — a silent edit to
//     either side is exactly how a runtime gets swapped without anyone noticing;
//   * the espeak (GPL-3.0) check must match the *symbol* form, because a case-insensitive search for
//     the bare word matches `OfflineSpeakerDiarization` ("...lin-eSpeak-er...") and would refuse
//     every clean build;
//   * the recovery branch runs for real over a temp directory, because promoting a complete backup
//     and purging an incomplete one is the one behaviour the ordering assertions cannot show.
//
// Without `Scripts/setup-speaker-diarization.sh`, `Resources/THIRD-PARTY-NOTICES.txt`, and the
// `build-app.sh` copy lines, every test below fails: the files do not exist to read or to run.

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // WhisperCoreTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // repo root
}

private func repositoryText(_ relativePath: String) throws -> String {
    try String(contentsOf: repositoryRoot().appendingPathComponent(relativePath), encoding: .utf8)
}

private func installerText() throws -> String {
    try repositoryText("Scripts/setup-speaker-diarization.sh")
}

private func allRanges(of needle: String, in text: String) -> [Range<String.Index>] {
    var found: [Range<String.Index>] = []
    var searchStart = text.startIndex
    while searchStart < text.endIndex,
          let range = text.range(of: needle, range: searchStart..<text.endIndex) {
        found.append(range)
        searchStart = range.upperBound
    }
    return found
}

/// The script text with every comment line removed, so an assertion about what the installer *does*
/// is never satisfied or defeated by prose explaining why.
private func installerCode(_ text: String) -> String {
    text
        .split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        .joined(separator: "\n")
}

/// The single `mv` that makes the staged runtime live. Everything that could refuse an install has
/// to happen before this offset or it cannot refuse anything.
private func activationOffset(in text: String) throws -> String.Index {
    let activations = allRanges(of: #"mv "$staging_directory" "$target_directory""#, in: text)
    #expect(activations.count == 1, "there must be exactly one activation site to reason about")
    return try #require(activations.first).lowerBound
}

@Test("The diarization installer's recovery-only guard is evaluated before the platform gate (F219)")
func diarizationInstallerChecksRecoveryModeBeforeThePlatformGate() throws {
    let text = try installerText()
    // Launch-time reclaim must not be refusable by a machine check: a build that cannot install can
    // still be holding an orphaned runtime that needs promoting (the F33 failure mode for Qwen).
    let recoveryGuard = try #require(text.range(of: "DIARIZATION_INSTALL_RECOVERY_ONLY"))
    let platformGate = try #require(text.range(of: #"$(uname -m)"#))
    let platformRefusal = try #require(text.range(of: "requires an Apple-silicon Mac"))
    #expect(recoveryGuard.upperBound < platformGate.lowerBound,
            "the platform gate must be conditioned on recovery mode, not evaluated ahead of it")
    #expect(platformGate.upperBound < platformRefusal.lowerBound)

    // …and the notices gate, which reads a file the bundle may be missing, is skipped the same way.
    let noticesGuard = try #require(text.range(of: #"if [[ ! -f "$notices_source" ]]; then"#))
    let noticesRecoverySkip = try #require(
        text.range(of: "DIARIZATION_INSTALL_RECOVERY_ONLY",
                   range: platformRefusal.upperBound..<text.endIndex)
    )
    #expect(noticesRecoverySkip.upperBound < noticesGuard.lowerBound)

    // The recovery branch exits before the disk check, so it can never reach a download.
    let recoveryExit = try #require(text.range(of: #"""
    if [[ "${DIARIZATION_INSTALL_RECOVERY_ONLY:-0}" == "1" ]]; then
      exit 0
    fi
    """#))
    let firstDownload = try #require(text.range(of: #"download "$sherpa_url""#))
    #expect(recoveryExit.upperBound < firstDownload.lowerBound,
            "recovery-only mode must exit before any network call")
}

@Test("Every diarization installer hash check precedes the atomic activation (F219)")
func diarizationInstallerVerifiesEveryHashBeforeActivation() throws {
    let text = try installerText()
    let activation = try activationOffset(in: text)

    let verifications = allRanges(of: #"verify_sha256 ""#, in: text)
    // Three downloaded artifacts plus five kept payload files, each verified exactly once.
    #expect(verifications.count == 8, "expected 8 hash checks, found \(verifications.count)")
    for verification in verifications {
        #expect(verification.upperBound < activation,
                "a hash check after the swap cannot stop a bad runtime from going live")
    }

    // A failed check must refuse rather than continue, and must say the existing install is intact.
    #expect(text.contains(
        #"Speaker-analysis $description verification failed; the existing runtime was not changed."#
    ))
    let helper = try #require(text.range(of: "verify_sha256() {"))
    #expect(helper.upperBound < verifications[0].lowerBound)
}

@Test("The licence and offline gates run before the diarization runtime is activated (F219)")
func diarizationInstallerGatesLicenceAndNetworkBeforeActivation() throws {
    let text = try installerText()
    let activation = try activationOffset(in: text)

    let espeakGate = try #require(text.range(of: "_espeak"))
    let socketGate = try #require(text.range(of: "_socket$"))
    let linkageGate = try #require(text.range(of: "libcurl|CFNetwork"))

    #expect(espeakGate.upperBound < activation,
            "a GPL-3.0 payload must be refused before it is installed, not audited afterwards")
    #expect(socketGate.upperBound < activation,
            "a binary that can open a socket must never reach the activated path")
    #expect(linkageGate.upperBound < activation)

    // Both gates must be refusals, not warnings.
    #expect(text.contains("failed its licence check; nothing was changed."))
    #expect(text.contains("failed its offline check; nothing was changed."))
}

@Test("The diarization installer prunes the download tree before hashing the kept payload (F219)")
func diarizationInstallerPrunesBeforeHashingThePayload() throws {
    let text = try installerText()
    let prune = try #require(text.range(of: #"rm -rf "$staging_directory/download""#))
    let firstPayloadHash = try #require(text.range(
        of: #"verify_sha256 "$staging_directory/bin/sherpa-onnx-offline-speaker-diarization""#
    ))
    // Hashing after the prune is what makes the check describe the runtime that actually ships: the
    // 29-binary tarball (which does contain socket-carrying websocket servers) is already gone.
    #expect(prune.upperBound < firstPayloadHash.lowerBound,
            "the payload hashes must describe the pruned tree, not the full extraction")
    #expect(prune.upperBound < (try activationOffset(in: text)))
}

@Test("The espeak check matches the symbol form, not the word inside OfflineSpeakerDiarization (F219)")
func diarizationInstallerMatchesEspeakAsASymbolNotAWord() throws {
    let text = try installerText()
    let gateLine = try #require(
        text.split(separator: "\n").first { $0.contains(#"grep -qE '_espeak"#) }
    )
    let quoted = gateLine.split(separator: "'")
    #expect(quoted.count >= 2, "the espeak gate must carry a single-quoted regex")
    let pattern = String(try #require(quoted.dropFirst().first))
    #expect(pattern == "_espeak[A-Za-z_0-9]*")

    let regex = try NSRegularExpression(pattern: pattern)
    func matches(_ candidate: String) -> Bool {
        regex.firstMatch(
            in: candidate,
            range: NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        ) != nil
    }

    // Real GPL-3.0 espeak-ng symbols, as a default (non `-no-tts`) sherpa-onnx build exports them.
    #expect(matches("0000000100abcd00 T _espeak_Synth"))
    #expect(matches("                 U _espeak_ng_InitializePath"))

    // Symbols the clean build really does export. "OfflineSpeaker" lowercases to "offlinespeaker",
    // which contains "espeak" — so a naive case-insensitive word search refuses every good install.
    for symbol in [
        "0000000100001234 T __ZN10sherpa_onnx26OfflineSpeakerDiarizationC1Ev",
        "0000000100005678 T __ZNK10sherpa_onnx24OfflineSpeakerSegmentation7ProcessE",
    ] {
        #expect(!matches(symbol), "the symbol pattern false-positived on \(symbol)")
        #expect(symbol.lowercased().contains("espeak"),
                "this fixture only proves its point if the naive search would have matched it")
    }

    let code = installerCode(text).lowercased()
    #expect(!code.contains("grep -i espeak"))
    #expect(!code.contains("grep -qi espeak"))
}

@Test("The diarization installer's pinned hashes match the F216 decision record (F219)")
func diarizationInstallerPinsMatchTheDecisionRecord() throws {
    let script = try installerText()
    let decision = try repositoryText("docs/DIARIZATION_RUNTIME_DECISION.md")

    // Parse the script's `<name>_sha256="<hex>"` constants.
    var scriptPins: [String: String] = [:]
    let assignment = try NSRegularExpression(
        pattern: #"^([a-z_]+_sha256)="([0-9a-f]{64})""#,
        options: [.anchorsMatchLines]
    )
    for match in assignment.matches(
        in: script,
        range: NSRange(script.startIndex..<script.endIndex, in: script)
    ) {
        guard let name = Range(match.range(at: 1), in: script),
              let value = Range(match.range(at: 2), in: script) else { continue }
        scriptPins[String(script[name])] = String(script[value])
    }
    #expect(scriptPins.count == 7, "expected 7 pinned hashes in the script, found \(scriptPins.count)")

    // Parse the decision record's "### Pins" table.
    let pinsHeading = try #require(decision.range(of: "### Pins"))
    let pinsEnd = try #require(decision.range(
        of: "### Configuration pin",
        range: pinsHeading.upperBound..<decision.endIndex
    ))
    let pinsTable = String(decision[pinsHeading.upperBound..<pinsEnd.lowerBound])
    let hex = try NSRegularExpression(pattern: "[0-9a-f]{64}")

    func documentedHash(forArtifact artifact: String) throws -> String {
        let rows = pinsTable
            .split(separator: "\n")
            .filter { $0.hasPrefix("|") && $0.contains("`\(artifact)`") }
        #expect(rows.count == 1, "expected exactly one pins row naming \(artifact), found \(rows.count)")
        let row = String(try #require(rows.first))
        let match = try #require(hex.firstMatch(
            in: row,
            range: NSRange(row.startIndex..<row.endIndex, in: row)
        ))
        let range = try #require(Range(match.range, in: row))
        return String(row[range])
    }

    let expected: [(constant: String, artifact: String)] = [
        ("sherpa_sha256", "sherpa-onnx-v1.13.8-osx-arm64-shared-no-tts.tar.bz2"),
        ("diarizer_sha256", "bin/sherpa-onnx-offline-speaker-diarization"),
        ("onnxruntime_sha256", "lib/libonnxruntime.dylib"),
        ("segmentation_asset_sha256", "sherpa-onnx-pyannote-segmentation-3-0.tar.bz2"),
        ("segmentation_model_sha256", "model.onnx"),
        ("segmentation_license_sha256", "LICENSE"),
        ("embedding_sha256", "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx"),
    ]
    for pin in expected {
        let pinned = try #require(scriptPins[pin.constant], "the script does not pin \(pin.constant)")
        let documented = try documentedHash(forArtifact: pin.artifact)
        #expect(pinned == documented,
                "\(pin.constant) disagrees with the decision record's pin for \(pin.artifact)")
    }

    // The threshold is part of the pin, and the configuration section re-derived it as 0.40 (F217).
    #expect(script.contains(#"cluster_threshold="0.40""#))
    #expect(decision.contains("--clustering.cluster-threshold=0.40"))
    // The upstream release path really is misspelled; "fixing" it 404s.
    #expect(script.contains("speaker-recongition-models"))
    // The int8 segmentation model measured far worse and must never be copied.
    let copies = installerCode(script).split(separator: "\n").filter { $0.hasPrefix("cp ") }
    #expect(!copies.contains { $0.contains("int8") })
}

@Test("build-app.sh bundles the diarization installer and its notices before signing (F219)")
func diarizationInstallerScriptAndNoticesAreBundled() throws {
    // Nothing else exercises Bundle.main resource lookup, so a forgotten copy line here passes the
    // whole suite and only fails inside the packaged .app — and a missing notices file makes the
    // installer refuse outright, because the runtime is not shippable without it.
    let build = try repositoryText("Scripts/build-app.sh")
    let scriptCopy = try #require(build.range(
        of: #"cp "Scripts/setup-speaker-diarization.sh" "$app_dir/Contents/Resources/setup-speaker-diarization.sh""#
    ))
    let noticesCopy = try #require(build.range(
        of: #"cp "Resources/THIRD-PARTY-NOTICES.txt" "$app_dir/Contents/Resources/THIRD-PARTY-NOTICES.txt""#
    ))
    #expect(build.contains(#"chmod +x "$app_dir/Contents/Resources/setup-speaker-diarization.sh""#))

    let signing = try #require(build.range(of: "codesign"))
    #expect(scriptCopy.upperBound < signing.lowerBound,
            "a resource copied after codesign invalidates the signature")
    #expect(noticesCopy.upperBound < signing.lowerBound)

    // The installer resolves the notices as a sibling, which is exactly what those copies produce.
    let installer = try installerText()
    #expect(installer.contains(#"notices_source="$script_directory/THIRD-PARTY-NOTICES.txt""#))

    let manager = FileManager.default
    let script = repositoryRoot().appendingPathComponent("Scripts/setup-speaker-diarization.sh")
    let notices = repositoryRoot().appendingPathComponent("Resources/THIRD-PARTY-NOTICES.txt")
    #expect(manager.fileExists(atPath: script.path))
    #expect(manager.fileExists(atPath: notices.path))
    #expect(manager.isExecutableFile(atPath: script.path), "the bundled installer must be executable")

    // The notices file is a licence obligation, not a placeholder: every attributed component and
    // the full Apache-2.0 text have to actually be in it.
    let noticesText = try repositoryText("Resources/THIRD-PARTY-NOTICES.txt")
    for required in [
        "sherpa-onnx", "ONNX Runtime", "pyannote", "3D-Speaker",
        "Apache License", "MIT License", "BSD 2-Clause",
        "END OF TERMS AND CONDITIONS",
    ] {
        #expect(noticesText.contains(required), "the notices file is missing \(required)")
    }
}

@Test("The diarization installer's recovery run promotes a complete backup and clears the lock (F219)")
func diarizationInstallerRecoveryPromotesACompleteBackup() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory
        .appendingPathComponent("WhisperMeetDiarizationInstallerTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? manager.removeItem(at: root) }
    try manager.createDirectory(at: root, withIntermediateDirectories: true)

    let target = root.appendingPathComponent("Diarization", isDirectory: true)
    let completeBackup = root.appendingPathComponent(".Diarization-backup-111", isDirectory: true)
    let incompleteBackup = root.appendingPathComponent(".Diarization-backup-222", isDirectory: true)
    let abandonedStage = root.appendingPathComponent(".Diarization-install-333", isDirectory: true)
    let lock = root.appendingPathComponent(".Diarization-install.lock")

    try makeCompleteDiarizationRuntime(at: completeBackup)
    try Data("old runtime".utf8).write(to: completeBackup.appendingPathComponent("marker"))
    // A half-unpacked staging tree renamed into place: enough to look like a runtime, not enough to
    // promote. Promoting it would leave the app pointing at a binary that cannot run.
    try manager.createDirectory(
        at: incompleteBackup.appendingPathComponent("bin", isDirectory: true),
        withIntermediateDirectories: true
    )
    try manager.createDirectory(at: abandonedStage, withIntermediateDirectories: true)

    let first = try runDiarizationRecovery(target: target)
    #expect(first.status == 0, Comment(rawValue: first.output))
    let promoted = try String(contentsOf: target.appendingPathComponent("marker"), encoding: .utf8)
    #expect(promoted == "old runtime", "the complete backup must be promoted to the canonical path")
    #expect(!manager.fileExists(atPath: completeBackup.path))
    #expect(!manager.fileExists(atPath: incompleteBackup.path), "an incomplete backup must be purged")
    #expect(!manager.fileExists(atPath: abandonedStage.path), "abandoned staging must be purged")
    #expect(!manager.fileExists(atPath: lock.path), "the lock must be released on exit")

    // With a healthy runtime in place a leftover backup is stale and must go — never promoted over
    // the live runtime.
    let staleBackup = root.appendingPathComponent(".Diarization-backup-444", isDirectory: true)
    try makeCompleteDiarizationRuntime(at: staleBackup)
    try Data("stale".utf8).write(to: staleBackup.appendingPathComponent("marker"))

    let second = try runDiarizationRecovery(target: target)
    #expect(second.status == 0, Comment(rawValue: second.output))
    #expect(!manager.fileExists(atPath: staleBackup.path))
    let survivor = try String(contentsOf: target.appendingPathComponent("marker"), encoding: .utf8)
    #expect(survivor == "old runtime")
    #expect(!manager.fileExists(atPath: lock.path))
}

/// Every file `runtime_is_complete` requires. Byte content is irrelevant to the reclaim logic; the
/// executable bit on the diarizer is not.
private func makeCompleteDiarizationRuntime(at directory: URL) throws {
    let manager = FileManager.default
    let diarizer = directory.appendingPathComponent("bin/sherpa-onnx-offline-speaker-diarization")
    let files: [URL] = [
        diarizer,
        directory.appendingPathComponent("lib/libonnxruntime.dylib"),
        directory.appendingPathComponent("models/segmentation/model.onnx"),
        directory.appendingPathComponent("models/segmentation/LICENSE"),
        directory.appendingPathComponent("models/embedding/campplus_zh_en.onnx"),
        directory.appendingPathComponent("THIRD-PARTY-NOTICES.txt"),
        directory.appendingPathComponent("MANIFEST"),
    ]
    for file in files {
        try manager.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("placeholder".utf8).write(to: file)
    }
    try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: diarizer.path)
}

private func runDiarizationRecovery(target: URL) throws -> (status: Int32, output: String) {
    let script = repositoryRoot().appendingPathComponent("Scripts/setup-speaker-diarization.sh")
    let pipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [script.path, target.path]
    var environment = ProcessInfo.processInfo.environment
    environment["DIARIZATION_INSTALL_RECOVERY_ONLY"] = "1"
    process.environment = environment
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}
