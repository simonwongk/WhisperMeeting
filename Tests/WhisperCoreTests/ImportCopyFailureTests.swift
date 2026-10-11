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

// F709 review (R4) — a waiting watched file is forgotten only when its stat says it is not there.
// Anything else leaves it waiting: forgetting a file that is still there loses it for good.

@Test("Only no such file, or a path through something that is not a folder, means a file is gone (F709 review)")
func noSuchFileMeansGone() {
    #expect(ImportCopyFailure.meansNoSuchFile(posix(ENOENT)))
    #expect(ImportCopyFailure.meansNoSuchFile(posix(ENOTDIR)))
    #expect(ImportCopyFailure.meansNoSuchFile(cocoa(NSFileReadNoSuchFileError, wrapping: posix(ENOENT))))
    #expect(ImportCopyFailure.meansNoSuchFile(cocoa(NSFileReadNoSuchFileError)), "a Cocoa no-such-file with no reason under it")
    #expect(ImportCopyFailure.meansNoSuchFile(CocoaError(.fileNoSuchFile)))
}

@Test("A stat that fails for any other reason does not mean the file is gone (F709 review)")
func otherStatFailuresAreNotAbsence() {
    #expect(!ImportCopyFailure.meansNoSuchFile(posix(EACCES)))
    #expect(!ImportCopyFailure.meansNoSuchFile(cocoa(NSFileReadNoPermissionError, wrapping: posix(EACCES))))
    #expect(!ImportCopyFailure.meansNoSuchFile(cocoa(NSFileReadUnknownError, wrapping: posix(EIO))))
    #expect(!ImportCopyFailure.meansNoSuchFile(cocoa(NSFileReadUnknownError, wrapping: posix(ETIMEDOUT))))
    // The POSIX reason decides over a Cocoa code that says otherwise.
    #expect(!ImportCopyFailure.meansNoSuchFile(cocoa(NSFileReadNoSuchFileError, wrapping: posix(EIO))))
    #expect(!ImportCopyFailure.meansNoSuchFile(cocoa(NSFileReadUnknownError)), "no reason given is not absence")
    struct Unrelated: Error {}
    #expect(!ImportCopyFailure.meansNoSuchFile(Unrelated()))
}
