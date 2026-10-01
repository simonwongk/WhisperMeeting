import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F389 — Export Diagnostics named each crash report (F370) and carried nothing from inside it. This
// drives the app-level call, `AppModel.diagnosticsJSON()`, with a fixture directory through the
// `diagnosticsCrashReports` seam, and asserts the crash's exception and symbols come back through it
// with no path. Never the user's own `~/Library/Logs/DiagnosticReports`: every test here replaces the
// seam before calling, and the default is pinned only as source text.

/// A minimal JSON crash report in Apple's layout — a one-line header, then the body — shaped like
/// F356's: an exception raised under `installTapOnBus`, reached from `MicDictationRecorder.start()`.
private let fixtureReport = #"""
{"app_name":"WhisperMeet","app_version":"1.4.0","build_version":"42","bug_type":"309","os_version":"macOS 26.0 (25A354)","name":"WhisperMeet"}
{
  "procPath" : "\/Users\/someone\/Applications\/WhisperMeet.app\/Contents\/MacOS\/WhisperMeet",
  "crashReporterKey" : "SENTINEL-CRASH-REPORTER-KEY",
  "exception" : {"codes":"0x0000000000000000, 0x0000000000000000","type":"EXC_CRASH","signal":"SIGABRT"},
  "termination" : {"namespace":"SIGNAL","indicator":"Abort trap: 6","byProc":"WhisperMeet","byPid":4242},
  "asi" : {"libsystem_c.dylib":["abort() called"]},
  "faultingThread" : 0,
  "threads" : [{"triggered":true,"frames":[
    {"imageOffset":2234,"symbol":"-[AVAudioNode installTapOnBus:bufferSize:format:block:]","imageIndex":1},
    {"imageOffset":40960,"sourceFile":"\/Users\/someone\/src\/MicDictationRecorder.swift","symbol":"MicDictationRecorder.start()","imageIndex":0}
  ]}],
  "usedImages" : [
    {"base":4370300928,"path":"\/Users\/someone\/Applications\/WhisperMeet.app\/Contents\/MacOS\/WhisperMeet","name":"WhisperMeet"},
    {"base":6442999999,"path":"\/System\/Library\/Frameworks\/AVFAudio.framework\/Versions\/A\/AVFAudio","name":"AVFAudio"}
  ]
}
"""#

@MainActor
private func makeModel(_ label: String) -> (AppModel, URL, () -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F389-\(label)-\(UUID().uuidString)")
    let reports = root.appendingPathComponent("DiagnosticReports", isDirectory: true)
    try? FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
    let suite = "F389.\(label).\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    model.diagnosticsCrashReports = { CrashReportInventory.reportsForDiagnostics(in: reports) }
    return (model, reports, {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    })
}

@MainActor
@Test("Export Diagnostics carries the crash's exception and crashed-thread symbols, and still no paths (F389)")
func diagnosticsExportCarriesTheCrashDigest() throws {
    let (model, reports, cleanup) = makeModel("digest")
    defer { cleanup() }
    let url = reports.appendingPathComponent("WhisperMeet-2026-09-21-120000.ips")
    try Data(fixtureReport.utf8).write(to: url)
    // A fixed time, so the emitted epoch and `log show` date cannot happen to contain a checked digit run.
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_758_000_000)],
                                          ofItemAtPath: url.path)

    let json = model.diagnosticsJSON()

    let root = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    #expect(root["crashReportCount"] as? Int == 1)
    let report = try #require((root["crashReports"] as? [[String: Any]])?.first)
    #expect(report["name"] as? String == "WhisperMeet-2026-09-21-120000.ips")
    let digest = try #require(report["digest"] as? [String: Any], "\(json)")
    #expect(digest["exceptionType"] as? String == "EXC_CRASH")
    #expect(digest["exceptionSignal"] as? String == "SIGABRT")
    #expect(digest["faultingThreadFrames"] as? [String] == [
        "AVFAudio -[AVAudioNode installTapOnBus:bufferSize:format:block:]",
        "WhisperMeet MicDictationRecorder.start()",
    ] as [String])
    #expect(json.contains("log show"), "F370's command for the exception reason is still there")

    for leak in ["/Users/", "/System/", "Library/Logs", "someone", "0x", "SENTINEL-CRASH-REPORTER-KEY",
                 "MicDictationRecorder.swift", "4242"] {
        #expect(!json.contains(leak), "\(leak) reached the diagnostics bundle")
    }
}

@MainActor
@Test("A crash report that is not in the JSON format is still listed by name, without a digest (F389)")
func diagnosticsExportListsAnUnreadableReportByName() throws {
    let (model, reports, cleanup) = makeModel("text")
    defer { cleanup() }
    try Data("Process: WhisperMeet [4242]\nPath: /Users/someone/x\n".utf8)
        .write(to: reports.appendingPathComponent("WhisperMeet-2026-09-21-120000.crash"))

    let json = model.diagnosticsJSON()

    let root = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    let report = try #require((root["crashReports"] as? [[String: Any]])?.first)
    #expect(report["name"] as? String == "WhisperMeet-2026-09-21-120000.crash")
    #expect(report["digest"] == nil)
    #expect(!json.contains("/Users/"))
}

@Test("The real export reads the user's own DiagnosticReports through the digesting reader (F389)")
func diagnosticsCrashReportsDefaultIsTheRealDirectory() throws {
    // Source text, not a call: calling the default would read the user's real crash reports.
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppModel.swift")
    let declaration = try #require(source.range(of: "var diagnosticsCrashReports: @Sendable () -> [CrashReportRecord] = {"))
    let body = String(source[declaration.upperBound...].prefix(200))
    let readsTheRealDirectory = body.contains(
        "CrashReportInventory.reportsForDiagnostics(in: CrashReportInventory.defaultDirectory())"
    )
    #expect(readsTheRealDirectory, "\(body)")

    let export = try #require(source.range(of: "func diagnosticsJSON() -> String {"))
    let exportBody = String(source[export.upperBound...].prefix(1_200))
    let usesTheSeam = exportBody.contains("crashReports: diagnosticsCrashReports()")
    #expect(usesTheSeam, "diagnosticsJSON does not read crash reports through the seam:\n\(exportBody)")
}
