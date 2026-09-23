import Foundation
import Testing

// F216/F219 — the speaker-analysis installer downloads 21.6 MB of Core ML bundles from the public
// internet, so its happy path cannot be exercised here. Every invariant that keeps a *bad* download
// from becoming the activated runtime is nonetheless checkable without a network, and those are the
// invariants that matter:
//
//   * a gate that runs after the swap is not a gate, so the ordering of the hash check, the
//     manifest-completeness check and the load-and-run smoke test against the single atomic
//     activation `mv` is asserted by byte offset in the script text (the `LinkImportScriptShapeTests`
//     precedent);
//   * the pinned hashes are the entire integrity story, so they are parsed out of the script and
//     compared against the pins table in `docs/DIARIZATION_RUNTIME_DECISION.md` — a silent edit to
//     either side is exactly how a runtime gets swapped without anyone noticing;
//   * download and verify live in ONE loop body, so "downloaded but never hashed" is not a state the
//     script can be edited into by adding a file to the manifest;
//   * the recovery branch runs for real over a temp directory, because promoting a complete backup
//     and purging an incomplete one is the one behaviour the ordering assertions cannot show.
//
// The sherpa-onnx era's espeak (GPL-3.0) symbol gate and socket/offline symbol gate are gone with
// the native binary they described: a `.mlmodelc` bundle is data, exports no symbols and links
// nothing. What replaces them is a manifest-completeness check — the staged tree must contain
// exactly the pinned files, no extras, and no symlinks — which is the same "refuse an unexpected
// payload" job applied to the payload we now actually ship.
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

/// The `model_manifest=( … )` table, parsed as `relative path -> SHA-256`. This is the installer's
/// entire integrity story and the single list every other completeness check is derived from.
func diarizationInstallerManifest(_ script: String) throws -> [(path: String, sha256: String)] {
    let start = try #require(script.range(of: "model_manifest=(\n"))
    let end = try #require(script.range(of: "\n)\n", range: start.upperBound..<script.endIndex))
    let body = script[start.upperBound..<end.lowerBound]
    return try body.split(separator: "\n").map { line in
        let entry = line.trimmingCharacters(in: .whitespaces)
        #expect(entry.hasPrefix("\"") && entry.hasSuffix("\""), "manifest entry is not quoted: \(entry)")
        let fields = entry.dropFirst().dropLast().split(separator: " ")
        #expect(fields.count == 2, "expected '<path> <sha256>', got: \(entry)")
        let hash = String(try #require(fields.last))
        #expect(
            hash.count == 64 && hash.allSatisfy { $0.isHexDigit && !$0.isUppercase },
            "not a lowercase SHA-256: \(hash)"
        )
        return (String(try #require(fields.first)), hash)
    }
}

@Test("The diarization installer's recovery-only guard is evaluated before the platform gate (F216)")
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

    // …and the two gates that read files the bundle may be missing — the notices and the smoke-test
    // command — are skipped the same way, or a build missing either could never reclaim.
    let noticesGuard = try #require(text.range(of: #"if [[ ! -f "$notices_source" ]]; then"#))
    let noticesRecoverySkip = try #require(
        text.range(of: "DIARIZATION_INSTALL_RECOVERY_ONLY",
                   range: platformRefusal.upperBound..<text.endIndex)
    )
    #expect(noticesRecoverySkip.upperBound < noticesGuard.lowerBound)
    // Anchored on the refusal rather than the `-x` test: the same test appears earlier where the
    // command is *resolved* (bundle path, then the checkout fallback), and that one is not a gate.
    let smokeCommandRefusal = try #require(
        text.range(of: "The speaker-analysis models cannot be verified on this Mac")
    )
    #expect(noticesRecoverySkip.upperBound < smokeCommandRefusal.lowerBound)
    let firstDownloadForGate = try #require(text.range(of: #"download "$model_base_url/"#))
    #expect(smokeCommandRefusal.upperBound < firstDownloadForGate.lowerBound,
            "refusing after 21.6 MB has been fetched is a worse way to say the same no")

    // The recovery branch exits before the disk check, so it can never reach a download.
    let recoveryExit = try #require(text.range(of: #"""
    if [[ "${DIARIZATION_INSTALL_RECOVERY_ONLY:-0}" == "1" ]]; then
      exit 0
    fi
    """#))
    let firstDownload = try #require(text.range(of: #"download "$model_base_url/"#))
    #expect(recoveryExit.upperBound < firstDownload.lowerBound,
            "recovery-only mode must exit before any network call")
}

@Test("Every downloaded diarization artifact is hashed in the same loop that fetched it (F216)")
func diarizationInstallerVerifiesEveryDownloadBeforeActivation() throws {
    let text = try installerText()
    let code = installerCode(text)
    let activation = try activationOffset(in: text)

    // One download site and one verify site, both inside the manifest loop. Counting call sites was
    // the old shape (three archives, five payload files); with a 21-file manifest the structural
    // guarantee is stronger: a file cannot be added to the manifest and skip its hash, because the
    // same iteration that fetches it hashes it.
    #expect(allRanges(of: "download \"", in: code).count == 1,
            "expected exactly one download call site, inside the manifest loop")
    #expect(allRanges(of: "verify_sha256 \"", in: code).count == 1,
            "expected exactly one verify_sha256 call site, inside the download loop")

    let loop = try #require(code.range(of: #"for entry in "${model_manifest[@]}"; do"#))
    let loopEnd = try #require(code.range(of: "\ndone\n", range: loop.upperBound..<code.endIndex))
    let body = code[loop.upperBound..<loopEnd.lowerBound]
    #expect(body.contains(#"download "$model_base_url/$relative_path" "$destination""#))
    #expect(body.contains(#"verify_sha256 "$destination" "$expected_sha256" "$relative_path""#))
    let downloadCall = try #require(body.range(of: "download \"$model_base_url"))
    let verifyCall = try #require(body.range(of: "verify_sha256 \""))
    #expect(downloadCall.upperBound < verifyCall.lowerBound)

    let verifyInFullText = try #require(text.range(of: #"verify_sha256 "$destination""#))
    #expect(verifyInFullText.upperBound < activation,
            "a hash check after the swap cannot stop a bad runtime from going live")

    // A failed check must refuse rather than continue, and must say the existing install is intact.
    #expect(text.contains(
        #"Speaker-analysis $description verification failed; the existing runtime was not changed."#
    ))
    let helper = try #require(text.range(of: "verify_sha256() {"))
    #expect(helper.upperBound < verifyInFullText.lowerBound)
}

@Test("The manifest-completeness check and the smoke test run before activation (F216)")
func diarizationInstallerGatesCompletenessAndLoadBeforeActivation() throws {
    let text = try installerText()
    let activation = try activationOffset(in: text)

    // The Core ML replacement for the espeak/socket symbol gates: the staged tree must be exactly
    // the pinned file list. An extra file is an unpinned, unhashed payload; a symlink is a path out
    // of the tree entirely. Both refuse.
    let completeness = try #require(text.range(of: "staged_models_match_manifest"))
    #expect(completeness.upperBound < activation,
            "an unexpected payload must be refused before it is installed, not audited afterwards")
    #expect(text.contains("failed its completeness check; nothing was changed."))
    #expect(text.contains(#"! -type d ! -type f"#),
            "the completeness check must refuse symlinks, not just count regular files")

    // …and the models are actually loaded and run before the swap. `--help` proved nothing about
    // inference for the old CLI; a staged directory of Core ML bundles that will not compile on
    // this Mac proves nothing either until something loads them.
    let smoke = try #require(text.range(of: #""$smoke_test_command" --diarization-smoke-test"#))
    #expect(smoke.upperBound < activation,
            "models that cannot load must never become the activated runtime")
    #expect(text.contains("failed its smoke test; nothing was changed."))

    // The espeak/socket gates described a native binary that no longer exists. Their presence now
    // would mean the script is auditing something it does not install.
    let code = installerCode(text)
    #expect(!code.contains("_espeak"))
    #expect(!code.contains("nm -u"))
    #expect(!code.contains("otool -L"))
}

@Test("The diarization installer pins every Core ML file and matches the decision record (F216)")
func diarizationInstallerPinsMatchTheDecisionRecord() throws {
    let script = try installerText()
    let decision = try repositoryText("docs/DIARIZATION_RUNTIME_DECISION.md")
    let manifest = try diarizationInstallerManifest(script)

    // Four compiled Core ML bundles of five files each, plus the PLDA parameters.
    #expect(manifest.count == 21, "expected 21 pinned files, found \(manifest.count)")
    for bundle in ["Segmentation", "FBank", "Embedding", "PldaRho"] {
        let files = manifest.filter { $0.path.hasPrefix("\(bundle).mlmodelc/") }
        #expect(files.count == 5, "\(bundle).mlmodelc should pin 5 files, found \(files.count)")
    }
    #expect(manifest.contains { $0.path == "plda-parameters.json" })
    #expect(Set(manifest.map(\.path)).count == manifest.count, "a path is pinned twice")

    // Parse the decision record's "### Pins" table and require the two to agree exactly.
    let pinsHeading = try #require(decision.range(of: "### Pins"))
    let pinsEnd = try #require(decision.range(
        of: "### Configuration pin",
        range: pinsHeading.upperBound..<decision.endIndex
    ))
    let pinsTable = String(decision[pinsHeading.upperBound..<pinsEnd.lowerBound])
    let row = try NSRegularExpression(pattern: #"^\|[^|]*\|\s*`([^`]+)`\s*\|[^|]*\|\s*`([0-9a-f]{64})`"#,
                                      options: [.anchorsMatchLines])
    var documented: [String: String] = [:]
    for match in row.matches(
        in: pinsTable, range: NSRange(pinsTable.startIndex..<pinsTable.endIndex, in: pinsTable)
    ) {
        guard let path = Range(match.range(at: 1), in: pinsTable),
              let hash = Range(match.range(at: 2), in: pinsTable) else { continue }
        documented[String(pinsTable[path])] = String(pinsTable[hash])
    }
    #expect(documented.count == manifest.count,
            "the decision record pins \(documented.count) files, the script pins \(manifest.count)")
    for pin in manifest {
        let recorded = try #require(documented[pin.path],
                                    "the decision record does not pin \(pin.path)")
        #expect(recorded == pin.sha256, "\(pin.path) disagrees with the decision record")
    }

    // The staged directory name is the landmine this whole adoption tripped over: `Repo.diarizer`
    // is the Hugging Face slug `…/speaker-diarization-coreml`, but `folderName` strips `-coreml`,
    // and the resulting error names the folder rather than the repo, so it misdirects.
    // Through `installerCode`, like the negative assertion below it and unlike the three of these
    // that used the raw text until F384. Every one of them is a claim about what the installer
    // *does* — which directory it stages, which host it fetches from, which threshold it pins —
    // and the paragraph above each is prose about exactly those things. F285 is a false positive
    // of precisely this shape, and this file already had the helper that prevents it.
    let code = installerCode(script)
    #expect(code.contains(#"model_directory_name="speaker-diarization""#))
    #expect(!code.contains("speaker-diarization-coreml/models"))
    #expect(code.contains("https://huggingface.co/${model_repo}/resolve/main"))
    // The threshold is part of the pin and belongs in the MANIFEST a result's sidecar is compared to.
    #expect(code.contains(#"cluster_threshold="0.6""#))
    #expect(decision.contains("clustering.threshold = 0.6"))
}

@Test("build-app.sh bundles the diarization installer and its notices before signing (F216)")
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

    // Match the actual invocation, not the word: a comment explaining a signing pitfall would
    // otherwise register as "signing happens here" and invert the whole ordering check.
    let signing = try #require(build.range(of: "codesign --force"))
    #expect(scriptCopy.upperBound < signing.lowerBound,
            "a resource copied after codesign invalidates the signature")
    #expect(noticesCopy.upperBound < signing.lowerBound)

    // The installer resolves the notices as a sibling, which is exactly what those copies produce,
    // and resolves the smoke-test command as the app executable one directory over — the layout
    // `Contents/{Resources,MacOS}` that build-app.sh writes.
    let installer = try installerText()
    #expect(installer.contains(#"notices_source="$script_directory/THIRD-PARTY-NOTICES.txt""#))
    #expect(installer.contains(#"smoke_test_command="${script_directory:h}/MacOS/WhisperMeet""#))
    #expect(build.contains(#"cp ".build/release/WhisperMeet" "$app_dir/Contents/MacOS/WhisperMeet""#))

    let manager = FileManager.default
    let script = repositoryRoot().appendingPathComponent("Scripts/setup-speaker-diarization.sh")
    let notices = repositoryRoot().appendingPathComponent("Resources/THIRD-PARTY-NOTICES.txt")
    #expect(manager.fileExists(atPath: script.path))
    #expect(manager.fileExists(atPath: notices.path))
    #expect(manager.isExecutableFile(atPath: script.path), "the bundled installer must be executable")

    // The notices file is a licence obligation, not a placeholder: every attributed component and
    // the full licence texts have to actually be in it. The Hugging Face model repo ships no licence
    // file at all (raw LICENSE → HTTP 404), so the CC-BY attribution below exists only here.
    let noticesText = try repositoryText("Resources/THIRD-PARTY-NOTICES.txt")
    for required in [
        "FluidAudio", "pyannote", "VBx", "fastcluster", "WeSpeaker",
        "Apache License", "Creative Commons Attribution 4.0",
        "END OF TERMS AND CONDITIONS",
        // CC-BY-4.0 §3(a)(1)(B) and §3(a)(1)(C): attribution plus an indication of modification.
        "Changes were made",
    ] {
        #expect(noticesText.contains(required), "the notices file is missing \(required)")
    }
    // The sherpa-onnx era's components are not shipped any more, and a notice for software we do
    // not ship is a false statement about the product.
    for removed in ["sherpa-onnx", "ONNX Runtime", "kaldi-native-fbank", "kaldi-decoder", "3D-Speaker"] {
        #expect(!noticesText.contains(removed), "the notices file still attributes \(removed)")
    }
}

@Test("The diarization installer's recovery run promotes a complete backup and clears the lock (F216)")
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
    // A half-downloaded staging tree renamed into place: enough to look like a runtime, not enough
    // to promote. Promoting it would leave the app pointing at models that cannot load.
    try makeCompleteDiarizationRuntime(at: incompleteBackup)
    try manager.removeItem(
        at: incompleteBackup
            .appendingPathComponent("models/speaker-diarization/Embedding.mlmodelc/weights/weight.bin")
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

/// Every file `runtime_is_complete` requires, built from the installer's own manifest so this
/// fixture can never describe a tree the script would reject. Byte content is irrelevant to the
/// reclaim logic; the paths are not.
private func makeCompleteDiarizationRuntime(at directory: URL) throws {
    let manager = FileManager.default
    let models = directory.appendingPathComponent("models/speaker-diarization", isDirectory: true)
    var files = try diarizationInstallerManifest(installerText())
        .map { models.appendingPathComponent($0.path) }
    files.append(directory.appendingPathComponent("THIRD-PARTY-NOTICES.txt"))
    files.append(directory.appendingPathComponent("MANIFEST"))
    for file in files {
        try manager.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("placeholder".utf8).write(to: file)
    }
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
