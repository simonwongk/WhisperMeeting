import Testing
import Foundation
@testable import WhisperCore

@Test("request round-trips through newline framing")
func requestRoundTrip() throws {
    let req = DictationRequest(wavPath: "/tmp/a.wav", language: "English", initialPrompt: nil)
    var buffer = try DictationWireProtocol.encodeLine(req)
    #expect(buffer.last == 0x0A)
    let line = DictationWireProtocol.takeLine(&buffer)
    #expect(line != nil)
    #expect(buffer.isEmpty)
    let decoded = try JSONDecoder().decode(DictationRequest.self, from: line!)
    #expect(decoded == req)
}

@Test("response decodes from a framed line")
func responseDecode() throws {
    let resp = DictationResponse(text: "hi", language: "en", error: nil)
    var buffer = try DictationWireProtocol.encodeLine(resp)
    let line = DictationWireProtocol.takeLine(&buffer)!
    #expect(try DictationWireProtocol.decodeResponse(line: line) == resp)
}

@Test("takeLine returns nil until a full line is present, then splits multiple")
func takeLinePartial() {
    var partial = Data("no newline yet".utf8)
    #expect(DictationWireProtocol.takeLine(&partial) == nil)
    var two = Data("first\nsecond\n".utf8)
    #expect(String(decoding: DictationWireProtocol.takeLine(&two)!, as: UTF8.self) == "first")
    #expect(String(decoding: DictationWireProtocol.takeLine(&two)!, as: UTF8.self) == "second")
    #expect(DictationWireProtocol.takeLine(&two) == nil)
}

@Test("rightOption hotkey default is keyCode 61 hold")
func hotkeyDefault() {
    #expect(DictationHotkey.rightOption == DictationHotkey(keyCode: 61, mode: .hold))
}

/// `DictationHotkey` exactly as every build before F548 coded it: synthesized `Codable` over a strict
/// enum. It stands in for the previously shipped build in both directions below.
private struct PreF548Hotkey: Codable, Equatable {
    enum Mode: String, Codable { case hold, toggle }
    var keyCode: UInt16
    var mode: Mode
}

@Test("A hotkey mode from a newer build decodes as hold on the same key (F548)")
func unknownHotkeyModeDecodesAsHoldOnTheSameKey() throws {
    // A newer build's mode, and a field this build has never heard of beside it.
    let newer = Data(#"{"keyCode":96,"mode":"doubleTap","tapInterval":0.3}"#.utf8)
    #expect(try JSONDecoder().decode(DictationHotkey.self, from: newer) == DictationHotkey(keyCode: 96, mode: .hold))
}

@Test("The hotkey's bytes are unchanged for known modes, and the previous build reads them (F548)")
func hotkeyWireShapeIsUnchangedForKnownModes() throws {
    let modes: [(DictationHotkey.Mode, PreF548Hotkey.Mode)] = [(.hold, .hold), (.toggle, .toggle)]
    for (mode, previousMode) in modes {
        let written = try JSONEncoder().encode(DictationHotkey(keyCode: 97, mode: mode))
        let previouslyWritten = try JSONEncoder().encode(PreF548Hotkey(keyCode: 97, mode: previousMode))
        #expect(written == previouslyWritten)
        // The previous build reads what this one writes, and this one reads what it wrote.
        #expect(try JSONDecoder().decode(PreF548Hotkey.self, from: written) == PreF548Hotkey(keyCode: 97, mode: previousMode))
        #expect(try JSONDecoder().decode(DictationHotkey.self, from: previouslyWritten) == DictationHotkey(keyCode: 97, mode: mode))
        // And the on-disk names themselves, which the twin cannot check if both are edited together.
        let object = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect(Set(object.keys) == ["keyCode", "mode"])
        #expect(object["keyCode"] as? Int == 97)
        #expect(object["mode"] as? String == mode.rawValue)
    }
}
