import Foundation
import Testing
@testable import WhisperCore

// F257 — every lifecycle hook and the app's only error surface hang off a view inside the
// `WindowGroup`, while the app deliberately stays alive with no window via `MenuBarExtra`. Recording
// from the menu bar with the window closed — a normal state during a meeting — means no
// `willTerminate` flush on quit, no startup-recovery summary, and **no alert at all**.
//
// That silences "Recovered Meeting … was added back to meeting history" and "changes could not be
// saved", which are the user-facing half of the recovery guarantees `PRODUCT_SPEC.md` promises in
// plain language. It also hides the `.atRisk` banner that is the only thing telling the user F253
// just happened.
//
// This is the decision half: what to do with a message that has nowhere to be shown.

@Test("A message is posted as a notification only when there is no window to show it in (F257)")
func postsOnlyWhenThereIsNoWindow() {
    #expect(WindowlessAlert.shouldPost(hasVisibleWindow: false, message: "Changes could not be saved."))
    // With a window the `.alert` host renders it, and a notification as well would be the same
    // message twice — which trains people to dismiss notifications from this app.
    #expect(!WindowlessAlert.shouldPost(hasVisibleWindow: true, message: "Changes could not be saved."))
}

@Test("An empty message is never posted (F257)")
func emptyMessagesAreNotPosted() {
    #expect(!WindowlessAlert.shouldPost(hasVisibleWindow: false, message: ""))
    #expect(!WindowlessAlert.shouldPost(hasVisibleWindow: false, message: "   \n "))
}

@Test("The notification names the app and carries the message as its body (F257)")
func contentIsTheMessage() {
    let content = WindowlessAlert.content(for: "Changes could not be saved.")
    #expect(content.title == "WhisperMeet")
    #expect(content.body == "Changes could not be saved.")
}

@Test("A long message is truncated on a word boundary, not mid-word (F257)")
func longMessagesTruncateCleanly() {
    // Notification bodies are clipped by the system anyway; truncating here means the cut is ours
    // and lands somewhere readable. `storageErrorMessage` can carry a whole `NSError` description.
    let long = String(repeating: "recovery ", count: 80)
    let content = WindowlessAlert.content(for: long)
    #expect(content.body.count <= WindowlessAlert.maximumBodyCharacters + 1)
    #expect(content.body.hasSuffix("…"))
    #expect(!content.body.contains("recov…"), "cut inside a word")
}

@Test("A message that fits is not given an ellipsis (F257)")
func shortMessagesAreUnchanged() {
    let content = WindowlessAlert.content(for: "Recovered Meeting was added back.")
    #expect(content.body == "Recovered Meeting was added back.")
    #expect(!content.body.hasSuffix("…"))
}

@Test("Newlines become spaces, so a multi-line alert reads as one line (F257)")
func newlinesAreFlattened() {
    // `alertMessage` is assembled with `\` continuations and embedded newlines for the in-window
    // alert, which renders them. A notification body does not, so it would show the raw breaks.
    let content = WindowlessAlert.content(for: "The library is readable.\n\nNothing was written.")
    #expect(!content.body.contains("\n"))
    #expect(content.body == "The library is readable. Nothing was written.")
}
