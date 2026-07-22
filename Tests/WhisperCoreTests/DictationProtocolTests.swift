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
