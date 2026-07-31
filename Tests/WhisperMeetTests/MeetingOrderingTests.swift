import Foundation
import Testing
@testable import WhisperMeet

/// F64 — pinned meetings sort to the top; within equal pin state, newest first; old indexes without
/// a `pinned` key still decode.
@Test("Pinned meetings sort first, then newest createdAt")
func pinnedMeetingsSortFirst() {
    let old = Date(timeIntervalSince1970: 100)
    let new = Date(timeIntervalSince1970: 200)
    let pinnedOld = MeetingRecord(title: "pinned", createdAt: old, pinned: true)
    let unpinnedNew = MeetingRecord(title: "new", createdAt: new)
    let unpinnedOld = MeetingRecord(title: "old", createdAt: old)

    let sorted = MeetingOrdering.sorted([unpinnedNew, pinnedOld, unpinnedOld])

    #expect(sorted.map(\.title) == ["pinned", "new", "old"])
}

@Test("A meetings index written before the pinned field still decodes")
func legacyIndexWithoutPinnedDecodes() throws {
    let json = Data("""
    [{"id":"1B4E28BA-2FA1-11D2-883F-0016D3CCA427","title":"m","createdAt":0,"duration":0,\
    "recordingPath":"","status":"recorded","transcriptText":"","segments":[]}]
    """.utf8)

    let decoded = try JSONDecoder().decode([MeetingRecord].self, from: json)

    #expect(decoded.first?.pinned == nil)
    #expect(decoded.first?.title == "m")
}
