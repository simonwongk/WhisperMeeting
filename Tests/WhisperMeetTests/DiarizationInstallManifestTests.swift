import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F216 — the installer and the app must agree, file for file, on what "installed" means.
//
// A recent review finding was exactly this drift: `Scripts/setup-speaker-diarization.sh` required
// one set of files and the Swift probe required a subset, so a tree the installer would have
// refused was reported healthy to the app, the Speaker Analysis menu entry enabled itself, and the
// first run died inside the runtime with an error the adapter has no case for. The two lists are
// now compared mechanically here rather than by inspection, because inspection is what failed.
//
// The second half of the drift is subtler and is why `fileExists` alone is not the predicate: four
// of the five artifacts are `.mlmodelc` *directories*. `FileManager.fileExists(atPath:)` is true for
// an empty directory, so a download interrupted after `mkdir -p` and before the first byte looked
// complete. The probe requires each of the 21 pinned paths to be a regular file.

private func installerScriptText() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // WhisperMeetTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // repo root
    return try String(
        contentsOf: root.appendingPathComponent("Scripts/setup-speaker-diarization.sh"),
        encoding: .utf8
    )
}

/// The relative paths in the installer's `model_manifest=( … )` table, in script order.
private func installerManifestPaths() throws -> [String] {
    let script = try installerScriptText()
    let start = try #require(script.range(of: "model_manifest=(\n"))
    let end = try #require(script.range(of: "\n)\n", range: start.upperBound..<script.endIndex))
    return script[start.upperBound..<end.lowerBound]
        .split(separator: "\n")
        .map { line in
            let entry = line.trimmingCharacters(in: .whitespaces).dropFirst().dropLast()
            return String(entry.split(separator: " ")[0])
        }
}

private func manifestTemporaryDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test("The installer's manifest and the Swift install probe require the same 21 files (F216)")
func diarizationInstallerManifestMatchesTheSwiftRequiredFiles() throws {
    let fromScript = try installerManifestPaths()
    let fromSwift = FluidAudioDiarizationRuntime.requiredModelFiles
    #expect(fromScript.count == 21, "the script pins \(fromScript.count) files, expected 21")
    #expect(
        Set(fromScript) == Set(fromSwift),
        """
        the installer and FluidAudioDiarizationRuntime disagree.
        only in the script: \(Set(fromScript).subtracting(fromSwift).sorted())
        only in Swift:      \(Set(fromSwift).subtracting(fromScript).sorted())
        """
    )
    // The five artifacts FluidAudio's own `ModelNames.OfflineDiarizer.requiredModels` names are the
    // roots of those 21 paths — the mapping from "what the SDK asks for" to "what we pin".
    for artifact in FluidAudioDiarizationRuntime.requiredModelArtifacts {
        let covered = fromSwift.filter { $0 == artifact || $0.hasPrefix("\(artifact)/") }
        #expect(!covered.isEmpty, "\(artifact) is not covered by any pinned path")
    }
}

@Test("The runtime reports itself uninstalled until every pinned file is present (F216)")
func fluidAudioRuntimeRequiresEveryPinnedFile() throws {
    let manager = FileManager.default
    let parent = try manifestTemporaryDirectory("FluidAudioCompleteness")
    defer { try? manager.removeItem(at: parent) }
    let models = parent.appendingPathComponent("speaker-diarization", isDirectory: true)
    #expect(FluidAudioDiarizationRuntime.isInstalled(inParent: parent) == false)

    let required = FluidAudioDiarizationRuntime.requiredModelFiles
    for (index, relative) in required.enumerated() {
        #expect(FluidAudioDiarizationRuntime.isInstalled(inParent: parent) == false,
                "reported installed with only \(index) of \(required.count) files staged")
        let file = models.appendingPathComponent(relative)
        try manager.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: file)
    }
    #expect(FluidAudioDiarizationRuntime.isInstalled(inParent: parent) == true)
}

@Test("A pinned path that is a directory is not a staged model file (F216)")
func fluidAudioRuntimeRefusesADirectoryWhereAFileIsPinned() throws {
    // `mkdir -p` runs before the first byte of every download. An interrupted install therefore
    // leaves the `.mlmodelc` directories in place and empty, and `fileExists(atPath:)` is true for
    // a directory — which is how "the folder exists" got mistaken for "the model is there".
    let manager = FileManager.default
    let parent = try manifestTemporaryDirectory("FluidAudioDirectoryStub")
    defer { try? manager.removeItem(at: parent) }
    let models = parent.appendingPathComponent("speaker-diarization", isDirectory: true)
    for relative in FluidAudioDiarizationRuntime.requiredModelFiles {
        let file = models.appendingPathComponent(relative)
        try manager.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: file)
    }
    #expect(FluidAudioDiarizationRuntime.isInstalled(inParent: parent) == true)

    let hollowed = models.appendingPathComponent(
        try #require(FluidAudioDiarizationRuntime.requiredModelFiles.first)
    )
    try manager.removeItem(at: hollowed)
    try manager.createDirectory(at: hollowed, withIntermediateDirectories: true)
    #expect(FluidAudioDiarizationRuntime.isInstalled(inParent: parent) == false,
            "an empty directory standing in for a model file must not read as installed")
}

@Test("The smoke-test flag is parsed only in its own complete form (F216)")
func diarizationSmokeTestParsesItsFlag() {
    #expect(DiarizationInstallSmokeTest.modelsParentDirectory(in: ["WhisperMeet"]) == nil)
    #expect(DiarizationInstallSmokeTest.modelsParentDirectory(
        in: ["WhisperMeet", "--diarization-smoke-test"]
    ) == nil, "a flag with no path must not be treated as a request")
    #expect(
        DiarizationInstallSmokeTest.modelsParentDirectory(
            in: ["WhisperMeet", "--diarization-smoke-test", "/tmp/models"]
        )?.path == "/tmp/models"
    )
    // The GUI must still launch for every ordinary argument vector, including one that merely
    // mentions the models directory.
    #expect(DiarizationInstallSmokeTest.modelsParentDirectory(
        in: ["WhisperMeet", "/tmp/models"]
    ) == nil)
}

@Test("The smoke test refuses a models directory that is not fully staged (F216)")
func diarizationSmokeTestRefusesAnIncompleteStagingTree() async throws {
    let parent = try manifestTemporaryDirectory("FluidAudioSmokeIncomplete")
    defer { try? FileManager.default.removeItem(at: parent) }
    let outcome = await DiarizationInstallSmokeTest.run(modelsParentDirectory: parent)
    #expect(outcome.status != 0)
    #expect(outcome.message.contains("speaker-diarization"),
            "the refusal must name what it looked for: \(outcome.message)")
}

// MARK: - Real staged models (opt-in)

private let smokeTestModels = ProcessInfo.processInfo.environment["WHISPERMEET_FLUIDAUDIO_MODELS"]

@Test(
    "The smoke test loads the real staged models and runs the pipeline on silence (F216)",
    .enabled(if: smokeTestModels != nil)
)
func diarizationSmokeTestPassesAgainstTheRealStagedModels() async throws {
    let parent = URL(fileURLWithPath: try #require(smokeTestModels))
    let outcome = await DiarizationInstallSmokeTest.run(modelsParentDirectory: parent)
    #expect(outcome.status == 0, Comment(rawValue: outcome.message))
    print("SMOKE TEST: \(outcome.message)")
}

@Test(
    "One second of silence is a result with no turns, not a failure (F216)",
    .enabled(if: smokeTestModels != nil)
)
func fluidAudioAdapterReturnsNoTurnsForSilence() async throws {
    // FluidAudio throws `OfflineDiarizationError.noSpeechDetected` rather than returning an empty
    // segment list. Surfaced raw that becomes `LocalDiarizationError.processFailed`, so a recording
    // that genuinely contains no speech — a meeting where the microphone was muted throughout —
    // would be reported to the user as a failed analysis instead of "no speakers found". The
    // sherpa-onnx runtime returned zero turns for the same input, and the app's overlay, sidecar and
    // UI all already handle a zero-turn result.
    let parent = URL(fileURLWithPath: try #require(smokeTestModels))
    let directory = try manifestTemporaryDirectory("FluidAudioSilence")
    defer { try? FileManager.default.removeItem(at: directory) }
    let audio = directory.appendingPathComponent("silence.wav")
    try DiarizationInstallSmokeTest.writeSilence(seconds: 1, to: audio)

    let client = FluidAudioDiarizationClient(modelsParentDirectory: parent)
    let result = try await client.diarize(audioURL: audio, durationSeconds: 1)

    #expect(result.turns.isEmpty)
    #expect(result.speakerCount == 0)
    #expect(result.audioSeconds == 1)
}
