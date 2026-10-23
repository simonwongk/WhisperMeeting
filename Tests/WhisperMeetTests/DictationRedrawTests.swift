import Foundation
import Testing
@testable import WhisperMeet

// F1090 — the main window held the dictation controller as an `@ObservedObject` only to hand it to the Dictation and Settings
// pages, which observe it themselves. So every dictation state change (listening, transcribing, done) re-ran the whole window's
// body, sidebar and page included, on the main thread in the turn before the pill could draw. It keeps a plain reference now;
// the pages that show the controller's state still observe it.
@Test("The main window keeps the dictation controller without observing it; the pages that show it observe it (F1090)")
func mainWindowDoesNotObserveDictation() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let start = try #require(source.range(of: "struct ContentView: View {"))
    let end = try #require(source.range(of: "\nprivate struct ", range: start.upperBound..<source.endIndex))
    let mainWindow = source[start.lowerBound..<end.lowerBound]
    #expect(!mainWindow.contains("@ObservedObject var dictation"), "the main window re-renders on every dictation state change")
    #expect(mainWindow.contains("let dictation: DictationController"))
    #expect(mainWindow.contains("DictationView(dictation: dictation"))
    #expect(mainWindow.contains("SettingsView(model: model, dictation: dictation)"))

    let settings = try #require(source.range(of: "struct SettingsView: View {"))
    #expect(source[settings.upperBound...].contains("@ObservedObject var dictation: DictationController"))
    let page = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/DictationView.swift")
    #expect(page.contains("@ObservedObject var dictation: DictationController"))
}
