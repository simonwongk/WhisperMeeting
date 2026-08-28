import Foundation
import Testing
@testable import WhisperCore

@Test("RefineRequest encodes to a single newline-terminated JSON line")
func refineRequestEncodesToOneLine() throws {
    let request = RefineRequest(text: "hello there", systemPrompt: "fix it", maxTokens: 256)
    let line = try DictationWireProtocol.encodeLine(request)
    #expect(line.last == 0x0A)
    #expect(!line.dropLast().contains(0x0A))
    let decoded = try JSONDecoder().decode(RefineRequest.self, from: line.dropLast())
    #expect(decoded == request)
}

@Test("RefineResponse decodes both success and error payloads")
func refineResponseDecodes() throws {
    let ok = try JSONDecoder().decode(
        RefineResponse.self, from: Data(#"{"text":"Hello there."}"#.utf8))
    #expect(ok.text == "Hello there.")
    #expect(ok.error == nil)
    let failed = try JSONDecoder().decode(
        RefineResponse.self, from: Data(#"{"error":"boom"}"#.utf8))
    #expect(failed.error == "boom")
}
