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

/// F590 — a full-width space (U+3000), which a Chinese IME can type between words, must split a
/// sidebar query into terms exactly as an ASCII space does.
@Test("A full-width-space-joined query matches what the ASCII-space query matches")
func fullWidthSpaceQueryMatchesAsciiSpaceQuery() {
    let fields = ["Weekly Sync", "budget discussion"]
    let f = facet(lang: "en", duration: 600, created: day("2026-07-15"), text: fields)

    let asciiQuery = MeetingQuery.parse("weekly budget")
    let fullWidthQuery = MeetingQuery.parse("weekly\u{3000}budget")

    #expect(fullWidthQuery.freeText == "weekly budget")
    #expect(fullWidthQuery.matches(f) == asciiQuery.matches(f))
    #expect(fullWidthQuery.matches(f))
}

// F568 Part 1 — `before:`/`after:YYYY-MM-DD` used to bound on UTC midnight while the sidebar shows
// each meeting's local month and day, so a meeting near local midnight landed on the wrong side of
// its own date. Explicit zones, never the host's: the instants are written in UTC.
private func instant(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

@Test("before:/after: bound on the start of the day in the given time zone (F568)")
func meetingQueryDateBoundsUseTheLocalDay() {
    let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    #expect(MeetingQuery.parseDate("2026-09-24", timeZone: shanghai) == instant("2026-09-23T16:00:00Z"))
    #expect(MeetingQuery.parseDate("2026-09-24", timeZone: losAngeles) == instant("2026-09-24T07:00:00Z"))

    // 07:30 on 24 Sep in Shanghai: shown as "Sep 24", so it is on/after the 24th and not before it.
    let shanghaiMorning = facet(lang: "en", duration: 600, created: instant("2026-09-23T23:30:00Z"))
    #expect(MeetingQuery.parse("after:2026-09-24", timeZone: shanghai).matches(shanghaiMorning))
    #expect(!MeetingQuery.parse("before:2026-09-24", timeZone: shanghai).matches(shanghaiMorning))

    // 18:00 on 23 Sep in Los Angeles: shown as "Sep 23", so it is before the 24th and not after it.
    let losAngelesEvening = facet(lang: "en", duration: 600, created: instant("2026-09-24T01:00:00Z"))
    #expect(!MeetingQuery.parse("after:2026-09-24", timeZone: losAngeles).matches(losAngelesEvening))
    #expect(MeetingQuery.parse("before:2026-09-24", timeZone: losAngeles).matches(losAngelesEvening))
}
