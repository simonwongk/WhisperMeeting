import Foundation
import Testing
@testable import WhisperCore

// F219 — the seam is the executable path, so the whole adapter is testable with a shell script
// that replays a recorded transcript: no models, no audio, no network.

@MainActor
private func makeFakeRuntime(
    stdout: String,
    stderr: String = "",
    exitStatus: Int = 0,
    body: String? = nil
) throws -> (directory: URL, client: LocalDiarizationClient) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiarizationClient-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appendingPathComponent("fake-diarizer")
    // Every run records its own argv beside the executable. The pinned flags are the central quality
    // decisions of this feature — the re-derived threshold, the flag that keeps the recording path
    // out of the log, and the flag that is deliberately never passed — and a fixture that discards
    // "$@" cannot notice any of them changing. `QwenClientFixture` records argv the same way.
    // `body` replaces the replay, not the whole script, so a runtime that hangs or writes its own
    // bytes still records argv. The default heredoc always ends its output with a newline, which is
    // why an override is the only way to reach the unterminated-final-line path.
    let replay = body ?? """
    cat <<'STDOUT_EOF'
    \(stdout)
    STDOUT_EOF
    print -u2 -- '\(stderr)'
    exit \(exitStatus)
    """
    let script = """
    #!/bin/zsh
    printf '%s\\n' "$@" > '\(directory.appendingPathComponent("arguments.txt").path)'
    \(replay)
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
@Test("The pinned analysis arguments are exactly the ones the runtime record specifies (F219)")
func clientPassesThePinnedArguments() async throws {
    let (directory, client) = try makeFakeRuntime(stdout: "Started")
    defer { try? FileManager.default.removeItem(at: directory) }
    let audio = directory.appendingPathComponent("audio.wav")

    _ = try await client.diarize(audioURL: audio, durationSeconds: 10, progress: { _ in })

    let arguments = try String(
        contentsOf: directory.appendingPathComponent("arguments.txt"), encoding: .utf8
    ).split(separator: "\n").map(String.init)
    // Pinned as an exact list, not a set of `contains` probes: a flag that appears is as much a
    // decision as one that does not, and `--clustering.num-clusters` is forbidden outright (§5 of
    // the runtime record — fixing the speaker count makes the runtime invent a second voice in a
    // monologue rather than report one).
    //
    // 0.40 was re-derived on the F217 corpus; Swift renders it `0.4`. 0.5 merges two same-gender
    // speakers into one cluster, which the overlay cannot detect: it sees one cluster, no
    // competitor, and labels confidently. `--print-args=false` keeps the full argv — including the
    // recording path — out of the runtime's own log.
    #expect(arguments == [
        "--print-args=false",
        "--clustering.cluster-threshold=0.4",
        "--clustering.compute-confidence=true",
        "--segmentation.num-threads=4",
        "--embedding.num-threads=4",
        "--segmentation.pyannote-model=\(directory.appendingPathComponent("segmentation.onnx").path)",
        "--embedding.model=\(directory.appendingPathComponent("embedding.onnx").path)",
        audio.path
    ])
    #expect(!arguments.contains { $0.hasPrefix("--clustering.num-clusters") })
}

@MainActor
@Test("Cancelling speaker analysis terminates the runtime process (F219)")
func clientCancellationTerminatesTheProcess() async throws {
    let pidPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiarizationCancel-\(UUID().uuidString).pid").path
    defer { try? FileManager.default.removeItem(atPath: pidPath) }
    // Cancelling a long-running child is the whole reason this adapter copies `LocalWhisperClient`'s
    // armedExitStream shape instead of calling `waitUntilExit()` (the F115/F121 hang), and every
    // other subprocess client here has this test. Without one, dropping the cancellation handler
    // costs nothing that any assertion notices.
    // `exec` so the recorded $$ is the pid of `sleep` itself, not of a shell that leaves it orphaned.
    let (directory, client) = try makeFakeRuntime(
        stdout: "", body: "printf '%s' $$ > '\(pidPath)'\nexec sleep 120\n"
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let audio = directory.appendingPathComponent("audio.wav")

    let task = Task { try await client.diarize(audioURL: audio, durationSeconds: 10) }
    try await Task.sleep(for: .milliseconds(300))
    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }

    // Throwing `CancellationError` is NOT evidence the child died: `AsyncStream` ends its own
    // iteration when the task is cancelled, so the loop unwinds and `Task.checkCancellation()`
    // throws within milliseconds even when nothing ever signals the process — which is exactly the
    // shape a gutted `onCancel` leaves behind, with a multi-GiB analysis still running. The pid is
    // the only thing that tells the two apart.
    let pid = pid_t(try String(contentsOf: URL(fileURLWithPath: pidPath), encoding: .utf8)) ?? 0
    #expect(pid > 0)
    var alive = true
    for _ in 0..<100 where alive {
        if kill(pid, 0) != 0 { alive = false } else { try await Task.sleep(for: .milliseconds(50)) }
    }
    #expect(!alive, "the runtime process \(pid) was left running after cancellation")
}

@MainActor
@Test("A final line with no trailing newline is still a turn (F219)")
func clientReadsAnUnterminatedFinalLine() async throws {
    // The runtime does not always end its last write with a newline. Every other fixture here goes
    // through a heredoc, which always adds one, so `pending` is always empty at EOF and nothing
    // exercises the flush path — gutting `flush()` to `return []` leaves the whole file green while
    // the last turn of a real run silently disappears.
    let (directory, client) = try makeFakeRuntime(stdout: "", body: """
    printf 'Started\\n'
    printf '2.000 -- 3.000 speaker_00'
    """)
    defer { try? FileManager.default.removeItem(at: directory) }

    let result = try await client.diarize(
        audioURL: directory.appendingPathComponent("audio.wav"),
        durationSeconds: 10
    )
    #expect(result.turns.count == 1)
    #expect(result.turns.first?.endSeconds == 3.0)
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
    // Pin the contract, not merely "something threw". `diarize` throws for several unrelated
    // reasons — a missing runtime, a launch failure, or any pre-check a later change adds in front
    // of the run (this fixture deliberately passes an audio path that does not exist) — and every
    // one of them would satisfy `thrown != nil` while never reaching `SpeakerTurns.validate` at
    // all. The escaping case and the reason both have to be named.
    guard case .processFailed(let detail)? = thrown as? LocalDiarizationError else {
        Issue.record("expected processFailed, got \(String(describing: thrown))")
        return
    }
    #expect(detail.contains("exceedsDuration"))
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

@Test("The tail of an over-long line is dropped, not resynced into the grammar (F219)")
func lineReaderDropsTheRestOfAnOversizedLine() {
    // The clamp fires on a chunk boundary, which nothing driving the real subprocess can place
    // deterministically — hence the direct test.
    var reader = DiarizationLineReader()
    _ = reader.consume("Started\n")
    // A damaged binary emitting one unbounded blob: the buffer is cleared to bound memory, and that
    // throws away the HEAD of the line. Emitting whatever arrives before the next terminator as a
    // line would hand the turn regex a fragment of that blob — which can parse.
    #expect(reader.consume(String(repeating: "x", count: 100_001)).isEmpty)
    #expect(reader.consume("0.000 -- 1.000 speaker_00\nprogress 10.00%\n") == ["progress 10.00%"])
}

@Test("An over-long line that never terminates is not flushed as a line either (F219)")
func lineReaderDoesNotFlushAnOversizedTail() {
    var reader = DiarizationLineReader()
    _ = reader.consume(String(repeating: "x", count: 100_001))
    _ = reader.consume("0.000 -- 1.000 speaker_00")
    // EOF is not a terminator that makes the rest of a discarded line legitimate.
    #expect(reader.flush().isEmpty)
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
