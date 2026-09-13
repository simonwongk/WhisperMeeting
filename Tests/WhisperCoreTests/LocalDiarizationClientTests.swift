import Foundation
import Testing
@testable import WhisperCore

// F219 — the seam is the executable path, so the whole adapter is testable with a shell script
// that replays a recorded transcript: no models, no audio, no network.

@MainActor
private func makeFakeRuntime(
    stdout: String,
    stderr: String = "",
    exitStatus: Int = 0
) throws -> (directory: URL, client: LocalDiarizationClient) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiarizationClient-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appendingPathComponent("fake-diarizer")
    let script = """
    #!/bin/zsh
    cat <<'STDOUT_EOF'
    \(stdout)
    STDOUT_EOF
    print -u2 -- '\(stderr)'
    exit \(exitStatus)
    """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let segmentation = directory.appendingPathComponent("segmentation.onnx")
    let embedding = directory.appendingPathComponent("embedding.onnx")
    try Data("seg".utf8).write(to: segmentation)
    try Data("emb".utf8).write(to: embedding)
    return (directory, LocalDiarizationClient(
        executableURL: executable,
        segmentationModelURL: segmentation,
        embeddingModelURL: embedding
    ))
}

@MainActor
@Test("A successful run yields validated, densely numbered turns (F219)")
func clientParsesASuccessfulRun() async throws {
    let (directory, client) = try makeFakeRuntime(stdout: """
    OfflineSpeakerDiarizationConfig(segmentation=...)
    Started
    0.031 -- 8.485 speaker_00 confidence=0.707
    8.975 -- 18.695 speaker_02 confidence=0.641
    """)
    defer { try? FileManager.default.removeItem(at: directory) }

    let result = try await client.diarize(
        audioURL: directory.appendingPathComponent("audio.wav"),
        durationSeconds: 20,
        progress: { _ in }
    )
    #expect(result.turns.map(\.clusterID) == [0, 1])
    #expect(result.speakerCount == 2)
    #expect(result.turns[0].startSeconds == 0.031)
}

@MainActor
@Test("Lines before `Started` are discarded so the config preamble never reaches a turn (F219)")
func clientDiscardsThePreamble() async throws {
    // The preamble embeds model paths; treating it as data would both break parsing and log paths.
    let (directory, client) = try makeFakeRuntime(stdout: """
    OfflineSpeakerDiarizationConfig(model="/secret/path/model.onnx")
    0.000 -- 1.000 speaker_09
    Started
    2.000 -- 3.000 speaker_00
    """)
    defer { try? FileManager.default.removeItem(at: directory) }

    let result = try await client.diarize(
        audioURL: directory.appendingPathComponent("audio.wav"),
        durationSeconds: 10,
        progress: { _ in }
    )
    #expect(result.turns.count == 1)
    #expect(result.turns[0].startSeconds == 2.0)
}

@MainActor
@Test("Zero turns with a clean exit is a legitimate empty result, not a failure (F219)")
func clientTreatsSilenceAsAnEmptyResult() async throws {
    let (directory, client) = try makeFakeRuntime(stdout: "Started")
    defer { try? FileManager.default.removeItem(at: directory) }

    let result = try await client.diarize(
        audioURL: directory.appendingPathComponent("audio.wav"),
        durationSeconds: 1,
        progress: { _ in }
    )
    #expect(result.turns.isEmpty)
    #expect(result.speakerCount == 0)
}

@MainActor
@Test("Progress lines on stderr reach the progress callback (F219)")
func clientReportsProgress() async throws {
    let (directory, client) = try makeFakeRuntime(
        stdout: "Started\n1.000 -- 2.000 speaker_00",
        stderr: "progress 50.00%"
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let box = ProgressBox()
    _ = try await client.diarize(
        audioURL: directory.appendingPathComponent("audio.wav"),
        durationSeconds: 10,
        progress: { fraction in box.values.append(fraction) }
    )
    #expect(box.values.contains(0.5))
}

@MainActor
@Test("A config failure maps to the damaged-runtime error (F219)")
func clientMapsConfigFailure() async throws {
    let (directory, client) = try makeFakeRuntime(stdout: "", stderr: "Errors in config!", exitStatus: 255)
    defer { try? FileManager.default.removeItem(at: directory) }

    var thrown: Error?
    do {
        _ = try await client.diarize(
            audioURL: directory.appendingPathComponent("audio.wav"),
            durationSeconds: 10,
            progress: { _ in }
        )
    } catch { thrown = error }
    guard case .runtimeDamaged = thrown as? LocalDiarizationError else {
        Issue.record("expected runtimeDamaged, got \(String(describing: thrown))")
        return
    }
}

@MainActor
@Test("A failure never puts the config preamble or a recording path in front of the user (F219)")
func clientKeepsThePreambleOutOfTheUserFacingError() async throws {
    // The runtime's line 1 embeds the recording path and both model paths, and `--print-args=false`
    // does not suppress it (DIARIZATION_RUNTIME_DECISION.md:585-591, :612, :647). It is gated out
    // of turn parsing already; it must also be gated out of the diagnostic that becomes an alert.
    let (directory, client) = try makeFakeRuntime(
        stdout: #"OfflineSpeakerDiarizationConfig(model="/Users/someone/Library/Application Support/WhisperMeet/Recordings/secret.wav")"#,
        stderr: "",
        exitStatus: 7
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    var thrown: Error?
    do {
        _ = try await client.diarize(
            audioURL: directory.appendingPathComponent("audio.wav"),
            durationSeconds: 10,
            progress: { _ in }
        )
    } catch { thrown = error }

    let message = (thrown as? LocalizedError)?.errorDescription ?? ""
    #expect(!message.contains("OfflineSpeakerDiarizationConfig"))
    #expect(!message.contains("secret.wav"))
    #expect(!message.contains("/Users/"))
    #expect(message == "Speaker analysis did not finish. Your transcript is unchanged.")

    // And not retained in the carried diagnostic either. The preamble is printed on every run, so it
    // is evidence of nothing; keeping the recording path in memory buys nothing and risks a log.
    guard case .processFailed(let detail)? = thrown as? LocalDiarizationError else {
        Issue.record("expected processFailed, got \(String(describing: thrown))")
        return
    }
    #expect(!detail.contains("OfflineSpeakerDiarizationConfig"))
    #expect(!detail.contains("secret.wav"))
}

@MainActor
@Test("A turn past the recording duration fails the whole run rather than being shown (F219)")
func clientValidatesAgainstDuration() async throws {
    let (directory, client) = try makeFakeRuntime(stdout: """
    Started
    0.000 -- 999.000 speaker_00
    """)
    defer { try? FileManager.default.removeItem(at: directory) }

    var thrown: Error?
    do {
        _ = try await client.diarize(
            audioURL: directory.appendingPathComponent("audio.wav"),
            durationSeconds: 10,
            progress: { _ in }
        )
    } catch { thrown = error }
    #expect(thrown != nil)
}

@Test("The diarization subprocess environment carries no proxy variables (F219)")
func clientEnvironmentDropsProxyVariables() {
    // The PRD promises analysis makes no network call. The binary links no network framework, but a
    // proxy variable in the inherited environment is the one thing that could make an unexpected
    // egress *look* configured, so it never reaches the child.
    let environment = LocalDiarizationClient.makeEnvironment(base: [
        "PATH": "/usr/bin:/bin",
        "HTTP_PROXY": "http://proxy:3128",
        "https_proxy": "http://proxy:3128",
        "ALL_PROXY": "socks5://proxy:1080",
        "all_proxy": "socks5://proxy:1080",
        "HTTPS_PROXY": "http://proxy:3128",
        "http_proxy": "http://proxy:3128"
    ])
    #expect(environment["PATH"] == "/usr/bin:/bin")
    for name in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] {
        #expect(environment[name] == nil, "\(name) reached the diarization subprocess")
    }
}

private final class ProgressBox: @unchecked Sendable {
    var values: [Double] = []
}

@Test("The runtime reports itself uninstalled when any required file is missing (F219)")
func runtimeInstallationPredicateRequiresEveryFile() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiarizationRuntime-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(DiarizationRuntime.isInstalled(applicationSupport: root) == false)

    // The seven files the installer's own `runtime_is_complete()` requires
    // (Scripts/setup-speaker-diarization.sh, DIARIZATION_RUNTIME_DECISION.md), added one at a time.
    // An install interrupted at ANY of these points must report uninstalled: checking a subset is
    // how a tree that dies on `@rpath/libonnxruntime.dylib` gets reported as healthy, and the dyld
    // error that follows has no `LocalDiarizationError` mapping at all.
    let required = [
        DiarizationRuntime.onnxRuntimeLibrary(applicationSupport: root),
        DiarizationRuntime.segmentationModel(applicationSupport: root),
        DiarizationRuntime.segmentationLicense(applicationSupport: root),
        DiarizationRuntime.embeddingModel(applicationSupport: root),
        DiarizationRuntime.thirdPartyNotices(applicationSupport: root),
        DiarizationRuntime.manifest(applicationSupport: root)
    ]
    let executable = DiarizationRuntime.executable(applicationSupport: root)
    try FileManager.default.createDirectory(
        at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: executable)
    // Present but not executable is not installed either.
    #expect(DiarizationRuntime.isInstalled(applicationSupport: root) == false)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    for file in required {
        #expect(DiarizationRuntime.isInstalled(applicationSupport: root) == false,
                "reported installed while \(file.lastPathComponent) was missing")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
    }
    #expect(DiarizationRuntime.isInstalled(applicationSupport: root) == true)
}
