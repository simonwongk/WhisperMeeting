import Foundation
import Testing
@testable import WhisperCore

// F389 — the diagnostics bundle named a crash report (F370) but carried nothing from inside it, so
// whoever was diagnosing still had to open the `.ips` by hand. `CrashReportDigest` reads the report
// by ALLOWLIST: the exception, the termination, the application-specific information, and the
// crashed thread's frames as "<image> <symbol>". Everything else in the file — paths, load
// addresses, the reporter key, the user ID, every other thread — is never read out.
//
// The fixture is hand-written in the layout Apple documents for the JSON crash report ("Interpreting
// the JSON format of a crash report"): a one-line header object, then the body object. No test reads
// a real `~/Library/Logs/DiagnosticReports` file; that is real crash data about real applications.

/// A synthetic `.ips` shaped like F356's crash: an Objective-C exception raised under
/// `installTapOnBus`, reached from `MicDictationRecorder.start()`. Every value that must NOT reach the
/// bundle is a sentinel or a path, so the leak checks below have something specific to look for.
let crashReportFixture = #"""
{"app_name":"WhisperMeet","timestamp":"2026-09-21 12:00:00.00 +0800","app_version":"1.4.0","slice_uuid":"11111111-2222-3333-4444-555555555555","build_version":"42","platform":1,"bundleID":"com.example.whispermeet","share_with_app_devs":0,"is_first_party":0,"bug_type":"309","os_version":"macOS 26.0 (25A354)","roots_installed":0,"name":"WhisperMeet","incident_id":"SENTINEL-INCIDENT-ID"}
{
  "uptime" : 86400,
  "procRole" : "Foreground",
  "version" : 2,
  "userID" : 501,
  "deployVersion" : 210,
  "modelCode" : "Mac15,6",
  "incident" : "SENTINEL-INCIDENT-ID",
  "pid" : 4242,
  "cpuType" : "ARM-64",
  "procName" : "WhisperMeet",
  "procPath" : "\/Users\/someone\/Applications\/WhisperMeet.app\/Contents\/MacOS\/WhisperMeet",
  "parentProc" : "launchd",
  "crashReporterKey" : "SENTINEL-CRASH-REPORTER-KEY",
  "sleepWakeUUID" : "SENTINEL-SLEEP-WAKE-UUID",
  "exception" : {"codes":"0x0000000000000000, 0x0000000000000000","rawCodes":[0,0],"type":"EXC_CRASH","signal":"SIGABRT"},
  "termination" : {"flags":0,"code":6,"namespace":"SIGNAL","indicator":"Abort trap: 6","byProc":"WhisperMeet","byPid":4242},
  "asi" : {
    "libsystem_c.dylib" : ["abort() called"],
    "CoreFoundation" : ["*** Terminating app due to uncaught exception 'com.apple.coreaudio.avfaudio', reason: 'required condition is false: format.sampleRate == hwFormat.sampleRate'"],
    "libswiftCore.dylib" : ["Fatal error at \/Users\/someone\/src\/Whisper\/Sources\/WhisperMeet\/AppModel.swift:42 object 0x600001234abc"]
  },
  "lastExceptionBacktrace" : [
    {"imageOffset":962124,"symbol":"__exceptionPreprocess","symbolLocation":176,"imageIndex":3},
    {"imageOffset":106668,"symbol":"objc_exception_throw","symbolLocation":88,"imageIndex":4},
    {"imageOffset":2234,"symbol":"-[AVAudioNode installTapOnBus:bufferSize:format:block:]","symbolLocation":324,"imageIndex":2},
    {"imageOffset":40960,"sourceLine":88,"sourceFile":"\/Users\/someone\/src\/Whisper\/Sources\/WhisperMeet\/Dictation\/MicDictationRecorder.swift","symbol":"MicDictationRecorder.start()","symbolLocation":512,"imageIndex":0}
  ],
  "faultingThread" : 0,
  "threads" : [
    {"triggered":true,"id":1234567,"threadState":{"pc":{"value":6442450944},"lr":{"value":6442450000}},"queue":"com.apple.main-thread","frames":[
      {"imageOffset":37980,"symbol":"__pthread_kill","symbolLocation":8,"imageIndex":5},
      {"imageOffset":26112,"symbol":"pthread_kill","symbolLocation":296,"imageIndex":6},
      {"imageOffset":479904,"symbol":"abort","symbolLocation":124,"imageIndex":1},
      {"imageOffset":2234,"symbol":"-[AVAudioNode installTapOnBus:bufferSize:format:block:]","symbolLocation":324,"imageIndex":2},
      {"imageOffset":40960,"sourceLine":88,"sourceFile":"\/Users\/someone\/src\/Whisper\/Sources\/WhisperMeet\/Dictation\/MicDictationRecorder.swift","symbol":"MicDictationRecorder.start()","symbolLocation":512,"imageIndex":0},
      {"imageOffset":12,"imageIndex":0},
      {"imageOffset":12,"symbol":"start","imageIndex":99}
    ]},
    {"id":1234568,"frames":[{"imageOffset":1,"symbol":"SENTINEL_OTHER_THREAD_SYMBOL","symbolLocation":0,"imageIndex":5}]}
  ],
  "usedImages" : [
    {"source":"P","arch":"arm64","base":4370300928,"size":1048576,"uuid":"SENTINEL-IMAGE-UUID","path":"\/Users\/someone\/Applications\/WhisperMeet.app\/Contents\/MacOS\/WhisperMeet","name":"WhisperMeet"},
    {"source":"P","arch":"arm64e","base":6442450944,"size":528384,"path":"\/usr\/lib\/system\/libsystem_c.dylib","name":"libsystem_c.dylib"},
    {"source":"P","arch":"arm64e","base":6442999999,"size":528384,"path":"\/System\/Library\/Frameworks\/AVFAudio.framework\/Versions\/A\/AVFAudio","name":"AVFAudio"},
    {"source":"P","arch":"arm64e","base":6443999999,"size":528384,"path":"\/System\/Library\/Frameworks\/CoreFoundation.framework\/Versions\/A\/CoreFoundation","name":"CoreFoundation"},
    {"source":"P","arch":"arm64e","base":6444999999,"size":528384,"path":"\/usr\/lib\/libobjc.A.dylib","name":"libobjc.A.dylib"},
    {"source":"P","arch":"arm64e","base":6445999999,"size":528384,"path":"\/usr\/lib\/system\/libsystem_kernel.dylib","name":"libsystem_kernel.dylib"},
    {"source":"P","arch":"arm64e","base":6446999999,"size":528384,"path":"\/usr\/lib\/system\/libsystem_pthread.dylib","name":"libsystem_pthread.dylib"}
  ],
  "vmSummary" : "SENTINEL_VM_SUMMARY \/Users\/someone\/Library\/Caches",
  "legacyInfo" : {"threadTriggered":{"queue":"com.apple.main-thread"}}
}
"""#

/// The bundle as a support reader would see it: the builder's JSON for one report with this digest.
private func bundle(for digest: CrashReportDigest?) -> String {
    DiagnosticsBundleBuilder.json(DiagnosticsInput(
        meetings: [], vocabulary: [],
        crashReports: [CrashReportRecord(fileName: "WhisperMeet-2026-09-21-120000.ips",
                                         writtenAt: Date(timeIntervalSince1970: 1_758_000_000),
                                         digest: digest)]
    ))
}

@Test("A crash report yields its exception, termination and the crashed thread's symbols (F389)")
func crashReportDigestReadsTheCrash() throws {
    let digest = try #require(CrashReportDigest.parse(Data(crashReportFixture.utf8)))
    #expect(digest.exceptionType == "EXC_CRASH")
    #expect(digest.exceptionSignal == "SIGABRT")
    #expect(digest.terminationNamespace == "SIGNAL")
    #expect(digest.terminationIndicator == "Abort trap: 6")
    #expect(digest.appVersion == "1.4.0 (42)")
    #expect(digest.osVersion == "macOS 26.0 (25A354)")
    #expect(digest.faultingThreadFrames == [
        "libsystem_kernel.dylib __pthread_kill",
        "libsystem_pthread.dylib pthread_kill",
        "libsystem_c.dylib abort",
        "AVFAudio -[AVAudioNode installTapOnBus:bufferSize:format:block:]",
        "WhisperMeet MicDictationRecorder.start()",
        "WhisperMeet ???",
        "??? start",
    ] as [String])
    #expect(digest.lastExceptionBacktrace.first == "CoreFoundation __exceptionPreprocess")
    #expect(digest.lastExceptionBacktrace.contains("AVFAudio -[AVAudioNode installTapOnBus:bufferSize:format:block:]"))
    #expect(digest.applicationSpecificInformation.contains("libsystem_c.dylib: abort() called"),
            "\(digest.applicationSpecificInformation)")
    #expect(digest.applicationSpecificInformation.contains { $0.contains("format.sampleRate == hwFormat.sampleRate") },
            "the exception reason is the useful part: \(digest.applicationSpecificInformation)")
}

@Test("The bundle carries the digest and nothing outside its allowlist: no path, address, key or other thread (F389)")
func crashReportDigestCarriesOnlyItsAllowlist() throws {
    let digest = try #require(CrashReportDigest.parse(Data(crashReportFixture.utf8)))
    let json = bundle(for: digest)
    #expect(json.contains("EXC_CRASH"))
    #expect(json.contains("installTapOnBus"))
    #expect(json.contains("MicDictationRecorder.start()"))
    // A path inside the application-specific information is redacted, its text kept.
    #expect(json.contains("Fatal error at <path>:42"), "\(json)")

    for leak in [
        "/Users/", "/System/", "/usr/lib", "/Applications", "Library/Caches", "someone",
        "0x", "SENTINEL-CRASH-REPORTER-KEY", "SENTINEL-SLEEP-WAKE-UUID", "SENTINEL-INCIDENT-ID",
        "SENTINEL-IMAGE-UUID", "SENTINEL_OTHER_THREAD_SYMBOL", "SENTINEL_VM_SUMMARY",
        "MicDictationRecorder.swift", "imageOffset", "sourceFile", "procPath", "userID", "501",
        "4242", "Mac15,6",
    ] {
        #expect(!json.contains(leak), "\(leak) reached the diagnostics bundle")
    }
}

@Test("Frames, entries and strings are capped, and an address in what is kept is redacted (F389)")
func crashReportDigestCapsWhatItCarries() throws {
    let manyFrames = (0..<60).map { #"{"imageOffset":\#($0),"symbol":"frame\#($0)","imageIndex":0}"# }
        .joined(separator: ",")
    let longReason = String(repeating: "x", count: 5_000)
    let manyEntries = (0..<20).map { #""e\#($0)""# }.joined(separator: ",")
    let report = #"""
    {"app_name":"WhisperMeet","bug_type":"309"}
    {"exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV","subtype":"KERN_INVALID_ADDRESS at 0x0000000000000010"},
     "asi":{"WhisperMeet":["\#(longReason)"],"libobjc.A.dylib":[\#(manyEntries)]},
     "faultingThread":1,
     "threads":[{"frames":[{"imageOffset":1,"symbol":"notTheCrashedThread","imageIndex":0}]},{"frames":[\#(manyFrames)]}],
     "lastExceptionBacktrace":[\#(manyFrames)],
     "usedImages":[{"name":"WhisperMeet","path":"\/Applications\/WhisperMeet.app\/Contents\/MacOS\/WhisperMeet"}]}
    """#
    let digest = try #require(CrashReportDigest.parse(Data(report.utf8)))
    #expect(digest.exceptionSubtype == "KERN_INVALID_ADDRESS at <addr>")
    #expect(digest.faultingThreadFrames.count == CrashReportDigest.frameLimit)
    #expect(digest.faultingThreadFrames.first == "WhisperMeet frame0", "faultingThread is an index into threads")
    #expect(digest.lastExceptionBacktrace.count == CrashReportDigest.frameLimit)
    #expect(digest.applicationSpecificInformation.count == CrashReportDigest.entryLimit)
    for entry in digest.applicationSpecificInformation {
        #expect(entry.count <= CrashReportDigest.stringLimit + 1, "\(entry.count) characters")
    }
    #expect(digest.appVersion == nil && digest.osVersion == nil)
}

@Test("Anything that is not a JSON crash report gives no digest, and never a crash (F389)")
func crashReportDigestRefusesWhatIsNotAReport() {
    let refused: [String] = [
        "",
        // F370's toy fixture: one line, no body.
        #"{"asi":"abort() called"}"#,
        "{\"asi\":\"abort() called\"}\n",
        // The pre-Monterey text format, which `.crash` files still use.
        "Process:               WhisperMeet [4242]\nPath:                  /Users/someone/Applications/WhisperMeet.app\n",
        // A header and a body with nothing on the allowlist (an analytics report, say).
        "{\"bug_type\":\"211\"}\n{\"foo\":1}",
        // A body that is not an object.
        "{\"bug_type\":\"309\"}\n[1,2,3]",
        // Truncated mid-write.
        "{\"bug_type\":\"309\"}\n{\"exception\":{\"type\":\"EXC_CRASH\"",
    ]
    for text in refused {
        #expect(CrashReportDigest.parse(Data(text.utf8)) == nil, "\(text.debugDescription)")
    }

    // Wrongly typed fields are skipped one by one rather than failing the report.
    let oddlyTyped = "{\"bug_type\":\"309\"}\n{\"exception\":{\"type\":\"EXC_CRASH\",\"signal\":6},\"faultingThread\":\"zero\",\"threads\":{\"a\":1},\"asi\":[\"x\"],\"usedImages\":7}"
    let digest = CrashReportDigest.parse(Data(oddlyTyped.utf8))
    #expect(digest?.exceptionType == "EXC_CRASH")
    #expect(digest?.exceptionSignal == nil)
    #expect(digest?.faultingThreadFrames == [])
    #expect(digest?.applicationSpecificInformation == [])
}

@Test("The diagnostics reader digests the newest reports it lists and leaves the rest as names (F389)")
func crashReportInventoryDigestsTheNewestReports() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiagnosticReports-F389-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let base = Date(timeIntervalSince1970: 1_758_000_000)
    func write(_ name: String, _ text: String, minutesAfterBase: Double) throws {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: base.addingTimeInterval(minutesAfterBase * 60)],
                                              ofItemAtPath: url.path)
    }
    try write("WhisperMeet-2026-09-21-130000.ips", crashReportFixture, minutesAfterBase: 3)
    try write("WhisperMeet-2026-09-21-120000.crash", "Process: WhisperMeet [4242]\n", minutesAfterBase: 2)
    try write("WhisperMeet-2026-09-21-110000.ips", crashReportFixture, minutesAfterBase: 1)
    try write("Safari-2026-09-21-130000.ips", crashReportFixture, minutesAfterBase: 4)

    let all = CrashReportInventory.reportsForDiagnostics(in: directory)
    #expect(all.map(\.fileName) == [
        "WhisperMeet-2026-09-21-130000.ips",
        "WhisperMeet-2026-09-21-120000.crash",
        "WhisperMeet-2026-09-21-110000.ips",
    ] as [String], "the same listing as F370's reader: ours only, newest first")
    #expect(all[0].digest?.exceptionType == "EXC_CRASH")
    #expect(all[1].digest == nil, "a text-format report is listed by name only")
    #expect(all[2].digest?.exceptionType == "EXC_CRASH")

    let limited = CrashReportInventory.reportsForDiagnostics(in: directory, digestLimit: 1)
    #expect(limited.map(\.fileName) == all.map(\.fileName), "the limit bounds the reading, not the listing")
    #expect(limited[0].digest != nil)
    #expect(limited[2].digest == nil)
}
