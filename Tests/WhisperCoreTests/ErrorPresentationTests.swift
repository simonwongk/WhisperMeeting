import Foundation
import Testing
@testable import WhisperCore

// F415 part 4 — `ErrorPresentation.sentence(for:fallback:)` discards the Swift-to-NSError bridge's
// placeholder ("The operation couldn’t be completed. (<domain> error <code>.)") and keeps real copy.
// It recognised the placeholder by the literal `error.domain`, but Foundation prints some domains
// by a short name, so those placeholders passed through as if they were sentences. F383 plans to
// route many more `localizedDescription` sites through this function, which is why the detector
// has to be right before it does.

/// An error type with no copy at all, so its bridged text is the placeholder.
private enum Mute: Error { case only }

@Test("A mute framework error falls back, whatever name Foundation prints for its domain (F415)")
func muteFrameworkErrorsFallBackUnderShortDomainNames() {
    let fallback = "The microphone could not be started."
    // Foundation renders these as "(OSStatus error -10868.)", "(Cocoa error 99999.)" and
    // "(Mach error 5 - (os/kern) failure)": none of them names the domain it was given.
    for error in [
        NSError(domain: NSOSStatusErrorDomain, code: -10_868),
        NSError(domain: NSCocoaErrorDomain, code: 99_999),
        NSError(domain: NSMachErrorDomain, code: 5),
    ] {
        #expect(ErrorPresentation.sentence(for: error, fallback: fallback) == fallback,
                "\(error.domain) \(error.code) passed through as: \(error.localizedDescription)")
    }
}

@Test("A placeholder that does name its domain still falls back (F366, F415)")
func placeholdersNamingTheirDomainStillFallBack() {
    let fallback = "fallback"
    #expect(ErrorPresentation.sentence(
        for: NSError(domain: "com.apple.coreaudio.avfaudio", code: -10_851), fallback: fallback
    ) == fallback)
    // `Mute` is private, so its domain reads `WhisperCoreTests.(unknown context at $…).Mute`: the
    // parentheses inside it are what a shape-only matcher misses, which this fix's first draft did.
    #expect(ErrorPresentation.sentence(for: Mute.only, fallback: fallback) == fallback)
}

@Test("Foundation's real sentences are kept, so the fallback is never a downgrade (F366, F415)")
func foundationsOwnSentencesAreKept() {
    for error in [
        NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError),
        NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)),
    ] {
        #expect(ErrorPresentation.sentence(for: error, fallback: "fallback") == error.localizedDescription,
                "\(error.domain) \(error.code)")
    }
}
