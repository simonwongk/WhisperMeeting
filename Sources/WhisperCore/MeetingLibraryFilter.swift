import Foundation

/// Composes the tested text-query and tag matchers into the single predicate the sidebar library uses
/// (F84 → delivers F67). A meeting is shown when it satisfies the optional text query AND the selected
/// tags. An empty query (`nil`) or empty selection passes that dimension through, so free-text search
/// and tag filtering stack rather than replace each other.
public enum MeetingLibraryFilter {
    public static func includes(
        query: MeetingQuery?,
        facets: MeetingFacets,
        meetingTags: [String],
        selectedTags: [String],
        tagMode: MeetingTags.MatchMode
    ) -> Bool {
        let matchesQuery = query?.matches(facets) ?? true
        return matchesQuery
            && MeetingTags.matches(meetingTags: meetingTags, selected: selectedTags, mode: tagMode)
    }
}
