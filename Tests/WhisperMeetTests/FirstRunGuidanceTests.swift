import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F565 — first-run guidance pointed where the control is not.
//
// 1. The "Before recording" panel's system-audio row said "Enable, then quit with ⌘Q" while
//    `CGPreflightScreenCaptureAccess()` was false — which on a fresh Mac only means "never asked".
//    WhisperMeet appears in System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording
//    only once `CGRequestScreenCaptureAccess()` has run, and only Start and Test Recording ran it,
//    so the user was sent to a list with nothing in it to enable.
// 2. "No transcription model is installed yet … Open Settings ▸ Transcription to install one" named
//    a section holding only the model and language pickers; the install buttons are under Local
//    recognition.

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
private func makeModel() throws -> (AppModel, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F565-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = AppModel(
        store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: testSuiteName())!,
        whisperExecutable: { nil }, qwenInstalled: { false }
    )
    return (model, root)
}

@MainActor
@Test("Allow… asks macOS, which is what puts WhisperMeet in System Settings' list, then opens that list (F565)")
func allowAsksAndThenOpensTheList() throws {
    let (model, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let asked = Counter(), opened = Counter()
    model.requestScreenCaptureAccess = { asked.increment(); return false }
    model.openScreenCaptureSettings = { opened.increment() }

    model.requestSystemAudioAccess()

    #expect(asked.count == 1, "only a request adds the app to the list; before one there is nothing to enable")
    #expect(opened.count == 1, "not granted yet, so the user is taken to the switch that is now there")
}

@MainActor
@Test("Allow… opens nothing when the request is granted outright (F565)")
func allowOpensNothingWhenGranted() throws {
    let (model, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let asked = Counter(), opened = Counter()
    model.requestScreenCaptureAccess = { asked.increment(); return true }
    model.openScreenCaptureSettings = { opened.increment() }

    model.requestSystemAudioAccess()

    #expect(asked.count == 1)
    #expect(opened.count == 0)
}

@Test("The system-audio row offers Allow… beside 'Enable, then quit with ⌘Q' (F565)")
func systemAudioRowOffersAllow() throws {
    let content = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let row = try #require(content.range(of: "private func preflightRow("))
    let notGranted = try #require(content[row.upperBound...].range(of: "case .notGranted:"))
    let branch = content[notGranted.upperBound...].prefix(600)
    #expect(branch.contains("Enable, then quit with ⌘Q"))
    #expect(branch.contains("Button(\"Allow…\")"), "the one control that puts WhisperMeet in the list")
    #expect(branch.contains("model.requestSystemAudioAccess()"))
}

/// The Settings sections a message names as `Settings ▸ <Section>`, matched against the section
/// headers ContentView actually has — derived, so a renamed section fails here rather than drifting.
/// Requires that every `Settings ▸` in the message named one of them.
private func settingsSections(namedIn message: String, source: String) throws -> [String] {
    let header = try NSRegularExpression(pattern: #"Section\((?:header: Label\()?"([^"]+)""#)
    let range = NSRange(source.startIndex..., in: source)
    let names = header.matches(in: source, range: range).compactMap {
        Range($0.range(at: 1), in: source).map { String(source[$0]) }
    }
    let named = names.filter { message.contains("Settings ▸ \($0)") }
    let pointers = message.components(separatedBy: "Settings ▸ ").count - 1
    #expect(named.count == pointers, "\"\(message)\" names a Settings section that does not exist")
    return named
}

/// The body of the Settings section with this header, up to the next section.
private func settingsSection(_ name: String, in source: String) throws -> Substring {
    let start = try #require(source.range(of: "Section(header: Label(\"\(name)\""),
                             "the message names Settings ▸ \(name), and Settings has no such section")
    let end = source[start.upperBound...].range(of: "Section(")?.lowerBound ?? source.endIndex
    return source[start.lowerBound..<end]
}

@Test("Every install instruction names the Settings section that holds the install buttons (F565)")
func installInstructionsNameTheSectionWithTheButtons() throws {
    let content = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")

    // Nothing installed: the one place to go is where "Install Local Whisper" is.
    let nothing = try #require(TranscriptionEngineAvailability.unavailableMessage(
        selected: .whisperLarge, isWhisperInstalled: false, isQwenInstalled: false
    ))
    let named = try settingsSections(namedIn: nothing, source: content)
    try #require(named.count == 1, "\(nothing)")
    #expect(try settingsSection(named[0], in: content).contains("model.installLocalWhisper()"),
            "\"\(nothing)\" sends the user to Settings ▸ \(named[0]), which has no install button")

    // Another engine installed: choose it where the model picker is, or install the selected one
    // where its install button is.
    let mismatch = try #require(TranscriptionEngineAvailability.unavailableMessage(
        selected: .qwenBalanced, isWhisperInstalled: true, isQwenInstalled: false
    ))
    let sections = try settingsSections(namedIn: mismatch, source: content)
    #expect(try sections.contains { try settingsSection($0, in: content).contains("Picker(\"Model\"") },
            "\"\(mismatch)\" must name the section with the model picker")
    #expect(try sections.contains { try settingsSection($0, in: content).contains("model.installQwenASR()") },
            "\"\(mismatch)\" says to install the selected model, so it must name where that button is")
}
