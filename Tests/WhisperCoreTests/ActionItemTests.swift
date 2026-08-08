import Foundation
import Testing
@testable import WhisperCore

// F177 — action items become structured, but a summary index written before F177 stored them as a
// plain array of strings. Decoding must accept both the old string form and the new object form so no
// stored summary is lost, and new items must round-trip as objects.

@Test("A summary with the old string-array action items decodes into text-only ActionItems (F177)")
func decodesLegacyStringActionItems() throws {
    let json = #"{"summary":"s","keyPoints":["k"],"actionItems":["Email vendor","Call Bob"]}"#
    let summary = try JSONDecoder().decode(MeetingSummary.self, from: Data(json.utf8))
    #expect(summary.actionItems == [ActionItem(text: "Email vendor"), ActionItem(text: "Call Bob")])
    #expect(summary.actionItems.allSatisfy { !$0.done && $0.owner == nil && $0.timestamp == nil })
}

@Test("A summary with the new object action items decodes every field (F177)")
func decodesStructuredActionItems() throws {
    let json = #"""
    {"summary":"s","keyPoints":[],"actionItems":[
      {"text":"Ship v1","done":true,"owner":"Alice","due":"Fri","quote":"we ship v1 friday","timestamp":42.0}
    ]}
    """#
    let summary = try JSONDecoder().decode(MeetingSummary.self, from: Data(json.utf8))
    let item = try #require(summary.actionItems.first)
    #expect(item == ActionItem(text: "Ship v1", done: true, owner: "Alice", due: "Fri",
                               quote: "we ship v1 friday", timestamp: 42.0))
}

@Test("A mixed string/object action-item array decodes both element forms (F177)")
func decodesMixedActionItems() throws {
    let json = #"{"summary":"s","keyPoints":[],"actionItems":["bare string",{"text":"an object","done":true}]}"#
    let summary = try JSONDecoder().decode(MeetingSummary.self, from: Data(json.utf8))
    #expect(summary.actionItems == [ActionItem(text: "bare string"), ActionItem(text: "an object", done: true)])
}

@Test("A structured action item round-trips through encode/decode unchanged (F177)")
func actionItemRoundTrips() throws {
    let original = MeetingSummary(
        summary: "s", keyPoints: ["k"],
        actionItems: [ActionItem(text: "x", done: true, owner: "A", due: "Mon", quote: "q", timestamp: 7)]
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(MeetingSummary.self, from: data)
    #expect(decoded == original)
}

@Test("ActionItem is expressible by a string literal for ergonomic construction (F177)")
func actionItemStringLiteral() {
    let item: ActionItem = "Email vendor"
    #expect(item == ActionItem(text: "Email vendor"))
}
