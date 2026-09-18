import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F184 — the link-import path against the real `yt-dlp`, real network, real `ffmpeg`. Off unless
// asked for, because it downloads:
//
//     REAL_LINK_IMPORT=1 swift test --filter RealLinkImport
//
// Drives `AppModel.importFromURL` — everything the sheet calls — against a throwaway library. The
// sheet itself (a text field and a button) is not exercised here.

private let enabled = ProcessInfo.processInfo.environment["REAL_LINK_IMPORT"] == "1"

@MainActor
private func makeModel() throws -> (AppModel, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RealLinkImport-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: "F184.\(UUID().uuidString)")!
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    model.linkImportEnabled = true
    return (model, root)
}

private func survivors(mentioning needle: String) -> [String] {
    let pipe = Pipe(); let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps"); ps.arguments = ["-axo", "pid=,command="]; ps.standardOutput = pipe
    try? ps.run()
    // Read BEFORE waiting: `ps` fills the pipe buffer, and waiting first deadlocks both sides.
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    ps.waitUntilExit()
    return text.split(separator: "\n").map(String.init).filter { $0.contains(needle) }
}

@MainActor
@Test("A real link imports end to end: meeting, provenance, tag, playable WAV (F184 item 1)", .enabled(if: enabled))
func realLinkImportsEndToEnd() async throws {
    let (model, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    // "Me at the zoo", 19 seconds: the smallest real thing there is.
    let id = try #require(await model.importFromURL("https://www.youtube.com/watch?v=jNQXAC9IVRw"), "\(model.alertMessage ?? "no message")")
    let meeting = try #require(model.store.meetings.first { $0.id == id })
    print("REAL title=\(meeting.title) duration=\(meeting.duration) tags=\(meeting.tags ?? []) source=\(meeting.source?.host ?? "-") videoID=\(meeting.source?.videoID ?? "-") status=\(meeting.status)")
    #expect(meeting.source?.videoID == "jNQXAC9IVRw")
    #expect(meeting.tags?.contains("YouTube") == true)
    #expect(abs(meeting.duration - 19) < 3)
    let header = try #require(WAVInspection.header(at: model.store.recordingURL(for: meeting)))
    #expect(header.sampleRate == 16_000 && header.channels == 1)
}

@MainActor
@Test("Stopping mid-download leaves no yt-dlp, no ffmpeg and no folder (F184 item 2)", .enabled(if: enabled))
func realCancelLeavesNothingBehind() async throws {
    let (model, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    // Big Buck Bunny (Blender Foundation, CC BY), ten minutes: long enough to be caught mid-transfer.
    // The 2026-08-08 run saw transient 403s that succeed on retry, so a start that fails before any
    // progress is retried; only a download actually in flight is worth cancelling.
    var task = Task { await model.importFromURL("https://www.youtube.com/watch?v=aqz-KE-bpKQ") }
    var sawProgress = false
    attempts: for attempt in 1...4 {
        for _ in 0..<600 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if let progress = model.mediaDownloadProgress, (progress.fractionCompleted ?? 0) > 0 { sawProgress = true; break attempts }
            if !model.isImporting, model.alertMessage != nil { break }
        }
        print("REAL attempt \(attempt) failed before progress: \(model.alertMessage ?? "-")")
        _ = await task.value
        model.alertMessage = nil
        task = Task { await model.importFromURL("https://www.youtube.com/watch?v=aqz-KE-bpKQ") }
    }
    #expect(sawProgress, "never reached a download in progress: \(model.alertMessage ?? "-")")
    let during = survivors(mentioning: root.lastPathComponent)
    print("REAL during cancel: \(during.count) process(es) working in the library")
    #expect(!during.isEmpty, "nothing was running to cancel, so this proved nothing")
    task.cancel()
    let result = await task.value
    try await Task.sleep(nanoseconds: 1_500_000_000)
    let after = survivors(mentioning: root.lastPathComponent)
    print("REAL after cancel: \(after)")
    #expect(result == nil)
    #expect(after.isEmpty)
    #expect(model.store.meetings.isEmpty)
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Recordings").path)) ?? []
    #expect(leftovers.isEmpty, "orphan folder: \(leftovers)")
    #expect(model.alertMessage == nil, "a cancel is not an error: \(model.alertMessage ?? "")")
}

@Test("A cancel kills a real ffmpeg spawned the way yt-dlp spawns it (F184 item 2)", .enabled(if: enabled))
func realCancelKillsARealFFmpegGrandchild() async throws {
    // yt-dlp's own transcode of a ten-minute file lasts a fraction of a second, and three attempts
    // to catch it in flight all lost the race. So the same shape is held open: the venv's Python
    // (what yt-dlp is) starts the real ffmpeg with `subprocess`, exactly as yt-dlp's postprocessor
    // does, in real-time mode so it runs for a minute unless killed.
    let python = try #require(MediaDownloadRuntime.findExecutable()).deletingLastPathComponent().appendingPathComponent("python")
    let ffmpeg = try #require(MediaDownloadRuntime.findFFmpeg())
    let marker = "f184-\(UUID().uuidString)"
    let script = "import subprocess; subprocess.run(['\(ffmpeg.path)', '-hide_banner', '-re', '-f', 'lavfi', '-i', 'sine=duration=60', '-metadata', 'comment=\(marker)', '-f', 'null', '-'])"
    let task = Task {
        try await ProcessGroupRunner().run(
            executableURL: python, arguments: ["-c", script],
            environment: MediaDownloadClient.makeEnvironment(), stallTimeout: 120
        )
    }
    var running: [String] = []
    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 100_000_000)
        running = survivors(mentioning: marker).filter { $0.contains("lavfi") && !$0.contains("import subprocess") }
        if !running.isEmpty { break }
    }
    print("REAL ffmpeg grandchild running before cancel: \(running.count)")
    #expect(running.count == 1)
    task.cancel()
    _ = try? await task.value
    try await Task.sleep(nanoseconds: 1_000_000_000)
    let after = survivors(mentioning: marker)
    print("REAL after cancel: \(after.count) process(es)")
    #expect(after.isEmpty)
}
