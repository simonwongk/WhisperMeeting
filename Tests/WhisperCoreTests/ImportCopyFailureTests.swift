import Foundation
import Testing
@testable import WhisperCore

// F554 — which copy failures can succeed later with the file unchanged. Foundation reports a failed
// copy as a Cocoa error and keeps the reason, if it keeps one, underneath it, so the classifier has
// to look below the top-level code.

private func posix(_ code: Int32) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code))
}

private func cocoa(_ code: Int, wrapping underlying: NSError? = nil) -> NSError {
    NSError(domain: NSCocoaErrorDomain, code: code,
            userInfo: underlying.map { [NSUnderlyingErrorKey: $0] } ?? [:])
}

@Test("A full disk, a dropped share and an I/O error are transient (F554)")
func transientCopyFailures() {
    #expect(ImportCopyFailure.isTransient(posix(ENOSPC)))
    #expect(ImportCopyFailure.isTransient(CocoaError(.fileWriteOutOfSpace)))
    #expect(ImportCopyFailure.isTransient(cocoa(NSFileWriteOutOfSpaceError, wrapping: posix(ENOSPC))))
    #expect(ImportCopyFailure.isTransient(cocoa(NSFileReadUnknownError, wrapping: posix(ETIMEDOUT))))
    #expect(ImportCopyFailure.isTransient(cocoa(NSFileReadUnknownError, wrapping: posix(ENOTCONN))))
    #expect(ImportCopyFailure.isTransient(cocoa(NSFileWriteUnknownError, wrapping: posix(EIO))))
    #expect(ImportCopyFailure.isTransient(POSIXError(.EDQUOT)))
}

@Test("A source whose volume went away is transient: it is back when the volume is (F554)")
func missingSourceIsTransient() {
    #expect(ImportCopyFailure.isTransient(cocoa(NSFileReadNoSuchFileError, wrapping: posix(ENOENT))))
    #expect(ImportCopyFailure.isTransient(cocoa(NSFileReadNoSuchFileError)))
}

@Test("The reason is found however deep Foundation nested it (F554)")
func nestedReasonIsFound() {
    let nested = cocoa(NSFileWriteUnknownError, wrapping: cocoa(NSFileReadUnknownError, wrapping: posix(EIO)))
    #expect(ImportCopyFailure.isTransient(nested))
}

@Test("A refusal that will not pass on its own is not transient (F554)")
func permanentCopyFailures() {
    #expect(!ImportCopyFailure.isTransient(posix(EACCES)))
    #expect(!ImportCopyFailure.isTransient(cocoa(NSFileReadNoPermissionError, wrapping: posix(EACCES))))
    #expect(!ImportCopyFailure.isTransient(cocoa(NSFileReadCorruptFileError)))
    #expect(!ImportCopyFailure.isTransient(cocoa(NSFileReadUnknownError)), "no reason given is no reason to retry")
    struct Unrelated: Error {}
    #expect(!ImportCopyFailure.isTransient(Unrelated()))
}
