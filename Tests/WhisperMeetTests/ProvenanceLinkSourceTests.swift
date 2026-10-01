import Foundation
import Testing

// F497 — the meeting header opened the persisted `pageURL` with no http(s) re-check, behind the
// separately stored `host`. `MediaSource.provenanceLink` (pinned in WhisperCoreTests'
// MediaSourceTests.swift) re-validates the URL and derives the label from it; this pins that the
// header opens that and nothing else, because the target has no view-render harness (F174).
// Comments are stripped first (F285). Each check is reduced to a Bool before `#expect`, so a
// failure names the check rather than printing the whole of ContentView.

@Test("The meeting header opens only MediaSource.provenanceLink, never the stored pageURL (F497)")
func provenanceHeaderOpensOnlyTheRecheckedLink() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let opensStoredPageURL = source.contains("URL(string: source.pageURL)")
    #expect(!opensStoredPageURL, "ContentView still builds a URL from the stored pageURL")

    let provenance = try #require(source.range(of: "if let source = meeting.source"))
    let block = String(source[provenance.lowerBound...].prefix(1_000))
    let usesRecheckedLink = block.contains("let link = source.provenanceLink")
        && block.contains("Link(link.label, destination: link.url)")
    #expect(usesRecheckedLink, "The provenance line does not open source.provenanceLink:\n\(block)")
    let labelsLinkWithStoredHost = block.contains("Link(source.host")
    #expect(!labelsLinkWithStoredHost, "The provenance Link is still labelled with the stored host")
}
