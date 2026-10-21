import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F893 — quitting WhisperMeet during a link import left yt-dlp and ffmpeg running after the app was
// gone. `ProcessGroupRunner` spawns yt-dlp as its own process-group leader and kills the group only on
// `cancel()`, and the import's task lived in the link sheet's `@State`: nothing on `AppModel` held it,
// and Quit (`AppLifecycle.onTerminate`) stopped only model installs (F520). The import's task is now
// held by the model, and Quit cancels it through the same `cancelWorkForQuit()` that stops installs.
//
// Both phases are driven here through the real runner, with stand-ins for the downloader: a leader
// still downloading, and a leader waiting on the ffmpeg it started in its own process group — what
// yt-dlp does for the audio extraction. Each must be gone after Quit, the child as well as the leader.

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
    let deadline = SuspendingClock.now + .seconds(30)
    while !condition() {
        guard SuspendingClock.now < deadline else { return false }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return true
}

/// A stand-in yt-dlp. In the download phase it prints progress lines; in the extraction phase it
/// starts a stand-in ffmpeg in its own process group, as yt-dlp's `FFmpegExtractAudioPP` does, and
/// waits for it. Each writes its pid, and either ends by itself after about a minute.
private func standInDownloader(in folder: URL, extracting: Bool) throws -> URL {
    let script = folder.appendingPathComponent("stand-in-yt-dlp.sh")
    let body = extracting
        ? """
        ( i=0; while [ $i -lt 600 ]; do sleep 0.1; i=$((i + 1)); done ) &
        echo $! > "\(folder.path)/child.pid"
        : > "\(folder.path)/started"
        wait
        """
        : """
        : > "\(folder.path)/started"
        i=0
        while [ $i -lt 600 ]; do
          echo '[download]  10.0% of 1.00MiB at 1.00KiB/s ETA 10:00'
          sleep 0.1
          i=$((i + 1))
        done
        """
    try """
    #!/bin/sh
    echo $$ > "\(folder.path)/leader.pid"
    \(body)
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
}

@MainActor
private func makeModel(root: URL, downloader: URL) -> AppModel {
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: testSuiteName())!
    )
    model.linkImportEnabled = true
    model.probeMediaURL = { _ in
        MediaProbe(title: "Quarterly review", durationSeconds: 600, uploader: "Acme", language: "en")
    }
    // The runner the real client uses, on the stand-in: a cancelled task signals its process group.
    model.downloadMedia = { _, directory, _ in
        _ = try await ProcessGroupRunner().run(
            executableURL: downloader, arguments: [], environment: ["PATH": "/usr/bin:/bin"], stallTimeout: 0
        )
        return directory.appendingPathComponent("recording.wav")
    }
    model.downloadCaptions = { _, _, _ in [] }
    return model
}

@MainActor
private func quitDuringImport(extracting: Bool) async throws {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("F893-\(extracting ? "extract" : "download")-\(UUID().uuidString)", isDirectory: true)
    let root = scratch.appendingPathComponent("library", isDirectory: true)
    let markers = scratch.appendingPathComponent("markers", isDirectory: true)
    try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        // Never leave a stand-in behind, whatever the outcome.
        for name in ["leader.pid", "child.pid"] {
            if let pid = readPID(markers.appendingPathComponent(name)) { kill(pid, SIGKILL) }
        }
        try? FileManager.default.removeItem(at: scratch)
    }
    let model = makeModel(root: root, downloader: try standInDownloader(in: markers, extracting: extracting))

    let task = model.startLinkImport("https://www.youtube.com/watch?v=abc123")
    try #require(await eventually { FileManager.default.fileExists(atPath: markers.appendingPathComponent("started").path) },
                 "the stand-in downloader never started")
    let leader = try #require(readPID(markers.appendingPathComponent("leader.pid")))
    var child: pid_t?
    if extracting {
        let found: pid_t = try #require(readPID(markers.appendingPathComponent("child.pid")))
        child = found
    }
    try #require(isAlive(leader))

    // What AppEntry wires `AppLifecycle.onTerminate` to.
    model.cancelWorkForQuit()

    let leaderStopped = await eventually { !isAlive(leader) }
    #expect(leaderStopped, "the downloader outlived Quit")
    if let child {
        let childStopped = await eventually { !isAlive(child) }
        #expect(childStopped, "the ffmpeg it started outlived Quit")
    }
    // A no-op when Quit stopped it; otherwise the test must not leave the import running.
    task.cancel()
    #expect(await task.value == .cancelled)
}

@MainActor
@Test("Quit during a link import's download stops the downloader (F893)")
func quitStopsALinkImportDownloading() async throws {
    try await quitDuringImport(extracting: false)
}

@MainActor
@Test("Quit during a link import's audio extraction stops the downloader and the ffmpeg it started (F893)")
func quitStopsALinkImportExtracting() async throws {
    try await quitDuringImport(extracting: true)
}

// Review of F893 (finding 4). The app is a `WindowGroup`, so two windows can each have a link sheet.
// The model held one task, the latest start, so a second window's Download — refused, since an
// import was running — took the running import's place, and Quit cancelled the refusal while the
// downloader ran on. And each sheet's Cancel stopped "the model's import", so Cancel or Escape on an
// idle sheet in another window stopped the running one, whose catch then deleted its folder.

@MainActor
@Test("A second start that is refused does not hide the running import from Quit, nor stop it (F893)")
func aRefusedSecondStartLeavesTheRunningImportToQuit() async throws {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("F893-second-\(UUID().uuidString)", isDirectory: true)
    let root = scratch.appendingPathComponent("library", isDirectory: true)
    let markers = scratch.appendingPathComponent("markers", isDirectory: true)
    try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        if let pid = readPID(markers.appendingPathComponent("leader.pid")) { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: scratch)
    }
    let model = makeModel(root: root, downloader: try standInDownloader(in: markers, extracting: false))

    let first = model.startLinkImport("https://www.youtube.com/watch?v=abc123")
    try #require(await eventually { FileManager.default.fileExists(atPath: markers.appendingPathComponent("started").path) },
                 "the stand-in downloader never started")
    let leader = try #require(readPID(markers.appendingPathComponent("leader.pid")))

    // Another window's sheet presses Download while the first import runs, and then its Stop.
    let second = model.startLinkImport("https://www.youtube.com/watch?v=other")
    try #require(await second.value == .refused(AppModel.linkImportBusy), "the second start was not refused")
    second.cancel()
    #expect(!first.isCancelled, "another start's task reached the running import")

    // What AppEntry wires `AppLifecycle.onTerminate` to.
    model.cancelWorkForQuit()

    #expect(first.isCancelled, "Quit did not reach the running import")
    let leaderStopped = await eventually { !isAlive(leader) }
    #expect(leaderStopped, "the downloader outlived Quit")
    first.cancel()
    _ = await first.value
}

@Test("Quit cancels the link imports, and a sheet starts its import through the model and stops only its own (F893)")
func quitAndTheSheetUseTheModelsLinkImport() throws {
    let entry = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppEntry.swift")
    let initRegion = try #require(entry.range(of: "var body: some Scene {")?.lowerBound)
    let wiring = entry.range(of: "lifecycle.onTerminate = { [weak model] in model?.cancelWorkForQuit() }")?.lowerBound
    #expect(wiring != nil, "AppEntry does not stop a link import on quit")
    if let wiring {
        #expect(wiring < initRegion, "the quit hook must be wired in init(), not in the window's .task (F465)")
    }

    let view = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let sheetStart = try #require(view.range(of: "private struct LinkImportSheet")?.lowerBound)
    let sheetEnd = try #require(view.range(of: "private struct AskMeetingsView")?.lowerBound)
    let sheet = String(view[sheetStart..<sheetEnd])
    let startsThroughTheModel = sheet.contains("model.startLinkImport(")
    let runsItsOwn = sheet.contains("model.importFromURL(")
    #expect(startsThroughTheModel, "the sheet does not start the import through the model")
    #expect(!runsItsOwn, "the sheet runs an import the model does not hold")
    // Its Stop cancels the task it started, and nothing that belongs to another window's sheet.
    let keepsItsTask = sheet.contains("runningImport = running")
    let stopsItsTask = sheet.contains("runningImport?.cancel()")
    let stopsTheModels = sheet.contains("model.cancelLinkImport")
    #expect(keepsItsTask, "the sheet does not keep the task it started")
    #expect(stopsItsTask, "the sheet's Stop does not stop its own import")
    #expect(!stopsTheModels, "the sheet's Stop can stop another window's import")
}
