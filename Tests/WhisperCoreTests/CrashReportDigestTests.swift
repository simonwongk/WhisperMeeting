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
    // A path inside the application-specific information cuts the message there: the text before it
    // is kept, the path and everything after it are not.
    #expect(json.contains("libswiftCore.dylib: Fatal error at <path>…"), "\(json)")
    #expect(!json.contains(":42 object"), "\(json)")

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

// F389 review: `DiagnosticsBundleBuilder.redactPaths` only recognises ASCII path components with no
// space in them, so on its own it left "<path>/会议记录/季度规划会议.mov" and
// "<path> Support<path> Meeting Q3.m4a" in the digest, and kept a quoted file name whole. A file name
// can be a meeting title, which F70 says the bundle never carries. These fixtures are the probes that
// found it plus the other shapes a path or a name takes in a crash message.

/// One `asi` message (and optionally an exception subtype) in a minimal JSON report, digested. The
/// body is built with `JSONSerialization` so the fixtures' quotes need no escaping.
private func digestOf(asi message: String, image: String = "Foundation", subtype: String? = nil) throws -> CrashReportDigest {
    var exception: [String: Any] = ["type": "EXC_CRASH"]
    if let subtype { exception["subtype"] = subtype }
    let body = try JSONSerialization.data(withJSONObject: ["exception": exception, "asi": [image: [message]]])
    return try #require(CrashReportDigest.parse(Data("{\"app_name\":\"WhisperMeet\",\"bug_type\":\"309\"}\n".utf8) + body))
}

/// Every fragment of a fixture's path or name: none of these may reach the bundle.
private let nameFragments = [
    "jane", "Jane", "会议记录", "季度规划会议", "Movies", "Library", "Application", "Support", "Recordings",
    "6F1C1D8E", "Board", "Meeting", "Q3", "Acme", "Merger", "Client", "Share", "Volumes", "Desktop",
    "Documents", "CloudDocs", "Plan", ".mov", ".wav", ".m4a",
]

@Test("Free text is cut at its first path, so no path segment or file name reaches the bundle (F389)")
func crashReportDigestCutsFreeTextAtItsFirstPath() throws {
    let fixtures: [(image: String, message: String, expected: String)] = [
        ("Foundation", "*** -[NSURL initFileURLWithPath:]: /Users/jane/Movies/会议记录/季度规划会议.mov is not valid",
         "Foundation: *** -[NSURL initFileURLWithPath:]: <path>…"),
        ("Foundation", "cannot open /Users/jane/Movies/会议记录/季度规划会议.mov",
         "Foundation: cannot open <path>…"),
        ("libswiftCore.dylib",
         #"Fatal error: 'try!' expression unexpectedly raised an error: Error Domain=NSCocoaErrorDomain Code=260 "The file “Board Meeting Q3.m4a” couldn’t be opened because there is no such file." UserInfo={NSFilePath=/Users/jane/Library/Application Support/WhisperMeet/Recordings/6F1C1D8E-1111-2222-3333-444455556666/Board Meeting Q3.m4a, NSUnderlyingError=0x600003e1c0f0}"#,
         #"libswiftCore.dylib: Fatal error: '<name>' expression unexpectedly raised an error: Error Domain=NSCocoaErrorDomain Code=260 "<name>" UserInfo={NSFilePath=<path>…"#),
        ("Foundation", "cannot open /Volumes/Client Share/Acme/Q3 Board.wav",
         "Foundation: cannot open <path>…"),
        ("Foundation", "cannot open file:///Users/jane/Documents/Acme Merger Call.wav",
         "Foundation: cannot open <path>…"),
        ("Foundation", "cannot open ~/Desktop/Acme Merger Call.wav",
         "Foundation: cannot open <path>…"),
        ("Foundation", "cannot open /Users/jane/Library/Mobile Documents/com~apple~CloudDocs/Meetings/Q3 Plan.wav",
         "Foundation: cannot open <path>…"),
    ]
    for fixture in fixtures {
        let digest = try digestOf(asi: fixture.message, image: fixture.image)
        #expect(digest.applicationSpecificInformation == [fixture.expected] as [String])
        let json = bundle(for: digest)
        for fragment in nameFragments + ["/"] {
            #expect(!json.contains(fragment), "\(fragment) reached the bundle from \(fixture.message)")
        }
    }

    // The exception subtype is free text too; its address is still replaced.
    let subtype = try digestOf(asi: "abort() called",
                             subtype: "KERN_INVALID_ADDRESS at 0x0000000000000010 in /Users/jane/Movies/会议记录/季度规划会议.mov")
    #expect(subtype.exceptionSubtype == "KERN_INVALID_ADDRESS at <addr> in <path>…")
    let json = bundle(for: subtype)
    for fragment in nameFragments + ["/"] {
        #expect(!json.contains(fragment), "\(fragment) reached the bundle from the exception subtype")
    }
}

@Test("A quoted name in free text is redacted, whichever quotes it is in (F389)")
func crashReportDigestRedactsQuotedNames() throws {
    let fixtures: [(message: String, expected: String)] = [
        ("Fatal error: Duplicate values for key: '季度规划会议'", "Foundation: Fatal error: Duplicate values for key: '<name>'"),
        ("Fatal error: Duplicate values for key: 'Acme Merger Call'", "Foundation: Fatal error: Duplicate values for key: '<name>'"),
        ("The file “Board Meeting Q3.m4a” couldn’t be opened.", "Foundation: The file “<name>” couldn’t be opened."),
        // An apostrophe inside the name does not close it; one outside a quote does not open one.
        ("cannot open ‘Jane’s Board Meeting.m4a’ for reading", "Foundation: cannot open ‘<name>’ for reading"),
        ("can't open 'Acme Merger Call.wav'", "Foundation: can't open '<name>'"),
        (#"cannot open "Acme Merger Call.wav""#, #"Foundation: cannot open "<name>""#),
        // A quote that never closes takes the rest of the message with it.
        ("cannot open “Board Meeting Q3.m4a", "Foundation: cannot open “<name>…"),
    ]
    for fixture in fixtures {
        let digest = try digestOf(asi: fixture.message)
        #expect(digest.applicationSpecificInformation == [fixture.expected] as [String])
        let json = bundle(for: digest)
        for fragment in nameFragments {
            #expect(!json.contains(fragment), "\(fragment) reached the bundle from \(fixture.message)")
        }
    }

    let subtype = try digestOf(asi: "abort() called", subtype: "cannot open “季度规划会议.mov”")
    #expect(subtype.exceptionSubtype == "cannot open “<name>”")
}

@Test("The uncaught-exception reason and a Swift file ID survive the cut; the exception's type, signal and termination are untouched (F389)")
func crashReportDigestKeepsTheExceptionReason() throws {
    // The preamble's own two quotes delimit the exception's name and reason, which are the useful part
    // (F356's reason is checked in crashReportDigestReadsTheCrash). A name or path inside the reason is
    // still redacted and cut.
    let nested = try digestOf(
        asi: "*** Terminating app due to uncaught exception 'NSInvalidArgumentException', reason: 'cannot open “Board Meeting Q3.m4a” at /Users/jane/Movies/会议记录/x.mov'",
        image: "CoreFoundation")
    #expect(nested.applicationSpecificInformation == [
        "CoreFoundation: *** Terminating app due to uncaught exception 'NSInvalidArgumentException', reason: 'cannot open “<name>” at <path>…",
    ] as [String])

    // A "name" that is not an identifier is not an exception name, so the quotes are names again.
    let notAName = try digestOf(
        asi: "*** Terminating app due to uncaught exception 'Board Meeting Q3', reason: 'x'", image: "CoreFoundation")
    #expect(notAName.applicationSpecificInformation == [
        "CoreFoundation: *** Terminating app due to uncaught exception '<name>', reason: '<name>'",
    ] as [String])

    // A Swift trap names its source as `Module/File.swift`, which is code, not a path on this Mac.
    let trap = try digestOf(
        asi: "WhisperCore/CrashReportDigest.swift:42: Fatal error: Unexpectedly found nil while unwrapping an Optional value",
        image: "libswiftCore.dylib")
    #expect(trap.applicationSpecificInformation == [
        "libswiftCore.dylib: WhisperCore/CrashReportDigest.swift:42: Fatal error: Unexpectedly found nil while unwrapping an Optional value",
    ] as [String])

    // Fixed vocabulary from the kernel and libsystem keeps the plain cleaning, quotes and all.
    let report = #"""
    {"app_name":"WhisperMeet","bug_type":"309"}
    {"exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},"termination":{"namespace":"SIGNAL","indicator":"Segmentation fault: 11 'x'"}}
    """#
    let plain = try #require(CrashReportDigest.parse(Data(report.utf8)))
    #expect(plain.exceptionType == "EXC_BAD_ACCESS")
    #expect(plain.exceptionSignal == "SIGSEGV")
    #expect(plain.terminationNamespace == "SIGNAL")
    #expect(plain.terminationIndicator == "Segmentation fault: 11 'x'")
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
