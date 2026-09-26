import Foundation
import Testing
@testable import WhisperCore

// F563 — the Web Page export wrote a bare `<html>`, so a screen reader voiced a Mandarin transcript
// in the reader's own language and the browser picked Han glyphs from the reader's locale.

private func html(languageCode: String?, text: String) -> String {
    TranscriptExporter.render(.html, TranscriptExportRequest(
        title: "t", languageCode: languageCode, durationSeconds: 0, transcriptText: text, segments: []
    ))
}

@Test("The Web Page export declares the transcript's language, and its Chinese script when the text says (F563)")
func htmlExportDeclaresTheTranscriptLanguage() {
    // Stored codes since F535; older records hold the engine's name for a pinned language.
    #expect(html(languageCode: "en", text: "We meet tomorrow.").contains("<html lang=\"en\">"))
    #expect(html(languageCode: "English", text: "We meet tomorrow.").contains("<html lang=\"en\">"))
    #expect(html(languageCode: "zh", text: "我们明天开会，然后讨论预算。").contains("<html lang=\"zh-Hans\">"))
    #expect(html(languageCode: "Chinese", text: "我們明天開會，然後討論預算。").contains("<html lang=\"zh-Hant\">"))
    // Characters both scripts share say nothing about which one this is, so no script is claimed.
    #expect(html(languageCode: "zh", text: "中文").contains("<html lang=\"zh\">"))
    // A language the engine detected that this app does not offer is still the text's language.
    #expect(html(languageCode: "ja", text: "こんにちは").contains("<html lang=\"ja\">"))
}

@Test("An unknown or malformed language omits the attribute rather than asserting one (F563)")
func htmlExportOmitsAnUnknownLanguage() {
    #expect(html(languageCode: nil, text: "Hello.").contains("<html>\n"))
    #expect(html(languageCode: "", text: "Hello.").contains("<html>\n"))
    let hostile = html(languageCode: "en\" onload=\"alert(1)", text: "Hello.")
    #expect(hostile.contains("<html>\n"))
    #expect(!hostile.contains("onload"))
}
