import Foundation
import Testing
@testable import WhisperCore

// F178 — local meeting templates reshape the summary's *structure* by appending guidance to the
// system prompt, while leaving the response schema and the do-not-translate clause untouched (F63).

@Test("Each non-general template adds its structural guidance to the system prompt (F178)")
func templateAddsGuidance() {
    #expect(ClaudeSummarizer.systemPrompt(language: nil, template: .decisionLog).contains("decision log"))
    #expect(ClaudeSummarizer.systemPrompt(language: nil, template: .oneOnOne).contains("1:1"))
    #expect(ClaudeSummarizer.systemPrompt(language: nil, template: .projectUpdate).contains("project update"))
    #expect(ClaudeSummarizer.systemPrompt(language: nil, template: .interview).contains("interview"))
    #expect(ClaudeSummarizer.systemPrompt(language: nil, template: .customerCall).contains("customer call"))
}

@Test("The general template adds nothing beyond the base + style prompt (F178)")
func generalTemplateIsBaseline() {
    let base = ClaudeSummarizer.systemPrompt(language: nil, style: .balanced)
    let general = ClaudeSummarizer.systemPrompt(language: nil, style: .balanced, template: .general)
    #expect(base == general)
}

@Test("Template composes with style — both guidances are present together (F178)")
func templateComposesWithStyle() {
    let prompt = ClaudeSummarizer.systemPrompt(language: nil, style: .actionItemsFocused, template: .decisionLog)
    #expect(prompt.lowercased().contains("action item")) // style guidance
    #expect(prompt.contains("decision log"))             // template guidance
}

@Test("Every template preserves the do-not-translate clause and the response schema (F178)")
func templatePreservesInvariants() {
    for template in MeetingTemplate.allCases {
        #expect(ClaudeSummarizer.systemPrompt(language: "en", template: template).contains("Do not translate"))
    }
    // The schema is independent of the template — it never gains or loses fields (F63 boundary).
    let schemaData = try? JSONSerialization.data(withJSONObject: ClaudeSummarizer.schema, options: [.sortedKeys])
    #expect(schemaData != nil)
    let props = ClaudeSummarizer.schema["properties"] as? [String: Any]
    #expect(props?.keys.sorted() == ["actionItems", "keyPoints", "summary"])
}
