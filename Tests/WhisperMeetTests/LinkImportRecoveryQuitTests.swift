import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F961 — Quit during startup recovery's own conversion of an interrupted link import left that ffmpeg
// running. `cancelWorkForQuit` stopped installs (F520), the link imports (F893) and, since F912, a
// conversion the launch had left to finish in the background — but not one the launch was still waiting
// for: its task was held by nothing on the model, so a Quit during the launch's wait (up to 30 s) sent it
// nothing, and the ffmpeg ran to the end of the download after the app was gone. The conversion's task
// is now held from the moment it starts until it ends, and Quit cancels it, which signals its process
// group through the runner's cancellation handler (the F893 mechanism).

/// Whether `pid` names a live process. A zombie still answers, so a reaped leader and an orphan
/// re-parented to launchd (which reaps it) are what make this false.
private func isAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

private func readPID(_ url: URL) -> pid_t? {
    (try? String(contentsOf: url, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

/// Polls `condition` until it holds or 30 s pass; the caller `#require`s the result.
private func eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(30)
    while !condition() {
        guard Date() < deadline else { return false }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return true
}

/// A stand-in for recovery's ffmpeg: writes its pid, says it has started, and runs for about a minute
/// unless it is signalled.
private func standInFFmpeg(in folder: URL) throws -> URL {
    let script = folder.appendingPathComponent("stand-in-ffmpeg.sh")
    try """
    #!/bin/sh
    echo $$ > "\(folder.path)/ffmpeg.pid"
    : > "\(folder.path)/started"
    i=0
    while [ $i -lt 600 ]; do sleep 0.1; i=$((i + 1)); done
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
}

/// `Recordings/<id>/` as the interrupted import left it: the sidecar, the complete download (bytes
/// AVFoundation cannot open, standing for Opus in WebM), and the WAV ffmpeg never finished.
private func makeInterruptedExtraction(in root: URL) throws -> (id: UUID, folder: URL) {
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = MediaSource(
        kind: MediaSource.webKind, pageURL: "https://example.com/watch?v=abc123", host: "example.com",
        videoID: "abc123", uploader: "Example Channel", fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try JSONEncoder().encode(source).write(to: folder.appendingPathComponent(MediaSource.sidecarFilename))
    try Data("a complete downloaded file".utf8).write(to: folder.appendingPathComponent("recording.webm"))
    var partial = WAVWriter.wavData(from: [Float](repeating: 0.1, count: 8_000), sampleRate: 16_000)
    let placeholder = Data([0xFF, 0xFF, 0xFF, 0xFF])
    partial.replaceSubrange(4..<8, with: placeholder)
    let dataTag = try #require(partial.range(of: Data("data".utf8)))
    partial.replaceSubrange(dataTag.upperBound..<(dataTag.upperBound + 4), with: placeholder)
    try partial.write(to: folder.appendingPathComponent("recording.wav"))
    return (id, folder)
}

@MainActor
@Test("Quit while the launch is still waiting for a recovery conversion stops that conversion's process (F961)")
func quitDuringTheLaunchesConversionWaitStopsIt() async throws {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("F961-\(UUID().uuidString)", isDirectory: true)
    let root = scratch.appendingPathComponent("library", isDirectory: true)
    let markers = scratch.appendingPathComponent("markers", isDirectory: true)
    try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let (id, folder) = try makeInterruptedExtraction(in: root)
    let model = AppModel(
        store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: testSuiteName())!
    )
    model.crashReportsSince = { _ in [] }
    defer {
        // Never leave the stand-in or the launch behind, whatever the outcome.
        for task in model.deferredLinkImportConversions.values { task.cancel() }
        if let pid = readPID(markers.appendingPathComponent("ffmpeg.pid")) { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: scratch)
    }
    // Longer than anything below waits: Quit comes while the launch is still waiting for the conversion,
    // not after it has left it to finish in the background (F912's case, tested beside this one).
    model.linkImportConversionWait = 45
    let ffmpeg = try standInFFmpeg(in: markers)
    model.finishInterruptedLinkImportExtraction = { download in
        // The runner the real conversion uses: a cancelled task signals its process group.
        _ = try await ProcessGroupRunner().run(
            executableURL: ffmpeg, arguments: [], environment: ["PATH": "/usr/bin:/bin"], stallTimeout: 0
        )
        let finished = download.deletingLastPathComponent().appendingPathComponent("recording.wav")
        try WAVWriter.wavData(from: [Float](repeating: 0.1, count: 8_000), sampleRate: 16_000).write(to: finished)
        return finished
    }

    let launch = Task { await model.performStartupRecovery() }
    defer { launch.cancel() }
    try #require(await eventually { FileManager.default.fileExists(atPath: markers.appendingPathComponent("started").path) },
                 "recovery's stand-in ffmpeg never started")
    let pid = try #require(readPID(markers.appendingPathComponent("ffmpeg.pid")))
    try #require(isAlive(pid))
    try #require(model.store.meeting(id: id) == nil, "fixture: indexed before the conversion ended")

    // What AppEntry wires `AppLifecycle.onTerminate` to.
    let quitAt = ProcessInfo.processInfo.systemUptime
    model.cancelWorkForQuit()

    let stopped = await eventually { !isAlive(pid) }
    #expect(stopped, "recovery's conversion outlived Quit")
    // The launch does not wait out the rest of its wait on a conversion that is gone, and indexes
    // nothing: the next launch finds the folder as it was and converts it again.
    await launch.value
    #expect(ProcessInfo.processInfo.systemUptime - quitAt < 20, "the launch waited out its wait after Quit")
    #expect(model.store.meeting(id: id) == nil, "a cancelled conversion indexed a meeting")
    #expect(model.deferredLinkImportConversions.isEmpty, "a cancelled conversion was left to finish in the background")
    for name in ["recording.webm", "recording.wav", MediaSource.sidecarFilename] {
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path), "\(name) was removed")
    }
}
