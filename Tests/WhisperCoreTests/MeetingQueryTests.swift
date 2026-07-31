import Foundation
import Testing
@testable import WhisperCore

private func day(_ s: String) -> Date { MeetingQuery.parseDate(s)! }

private func facet(
    lang: String?,
    status: String = "completed",
    duration: TimeInterval,
    created: Date,
    text: [String] = ["Weekly Sync", "transcript body"]
) -> MeetingFacets {
    MeetingFacets(
        languageCode: lang,
        status: status,
        durationSeconds: duration,
        createdAt: created,
        textFields: text
    )
}

/// F59 — faceted meeting search: language / status / date / duration tokens plus free text.
@Test("MeetingQuery filters by language, duration, and date facets")
func meetingQueryFiltersFacets() {
    let july = day("2026-07-15")
    let may = day("2026-05-15")

    // lang:zh excludes an English facet, keeps a Chinese one.
    #expect(!MeetingQuery.parse("lang:zh").matches(facet(lang: "en", duration: 600, created: july)))
    #expect(MeetingQuery.parse("lang:zh").matches(facet(lang: "zh", duration: 600, created: july)))

    // min:30m excludes a 10-minute meeting, keeps a 40-minute one.
    #expect(!MeetingQuery.parse("min:30m").matches(facet(lang: "en", duration: 600, created: july)))
    #expect(MeetingQuery.parse("min:30m").matches(facet(lang: "en", duration: 2400, created: july)))

    // before:2026-06-01 excludes a July facet, keeps a May one.
    #expect(!MeetingQuery.parse("before:2026-06-01").matches(facet(lang: "en", duration: 600, created: july)))
    #expect(MeetingQuery.parse("before:2026-06-01").matches(facet(lang: "en", duration: 600, created: may)))
}

@Test("A bare-word MeetingQuery matches identically to a direct TextSearch call")
func meetingQueryFreeTextRegressionGuard() {
    let fields = ["Weekly Sync", "budget discussion"]
    let f = facet(lang: "en", duration: 600, created: day("2026-07-15"), text: fields)

    #expect(MeetingQuery.parse("budget").matches(f) == TextSearch.matches("budget", in: fields))
    #expect(MeetingQuery.parse("invoice").matches(f) == TextSearch.matches("invoice", in: fields))
}
