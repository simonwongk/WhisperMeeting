import Foundation
import Testing
@testable import WhisperCore

// F180 — the "Ask Meetings" scope: only completed meetings, filtered by the selected tags (empty
// selection = all completed). Pure so it is tested without an @MainActor store.

@Test("An empty tag scope matches every completed meeting, and excludes non-completed (F180)")
func emptyScopeMatchesAllCompleted() {
    let scope = MeetingScope(tags: [])
    #expect(MeetingScopeResolver.inScope(tags: ["anything"], isCompleted: true, scope: scope))
    #expect(!MeetingScopeResolver.inScope(tags: ["anything"], isCompleted: false, scope: scope))
}

@Test("Tag .any scope matches a meeting carrying at least one selected tag (F180)")
func tagAnyScope() {
    let scope = MeetingScope(tags: ["pricing"], tagMode: .any)
    #expect(MeetingScopeResolver.inScope(tags: ["pricing", "q3"], isCompleted: true, scope: scope))
    #expect(!MeetingScopeResolver.inScope(tags: ["hiring"], isCompleted: true, scope: scope))
}

@Test("Tag .all scope requires every selected tag (F180)")
func tagAllScope() {
    let scope = MeetingScope(tags: ["a", "b"], tagMode: .all)
    #expect(MeetingScopeResolver.inScope(tags: ["a", "b", "c"], isCompleted: true, scope: scope))
    #expect(!MeetingScopeResolver.inScope(tags: ["a"], isCompleted: true, scope: scope))
}

@Test("A non-completed meeting is excluded even when its tags match (F180)")
func incompleteExcludedEvenWhenTagsMatch() {
    let scope = MeetingScope(tags: ["pricing"], tagMode: .any)
    #expect(!MeetingScopeResolver.inScope(tags: ["pricing"], isCompleted: false, scope: scope))
}
