import Foundation

/// Whether a failure to copy an imported file into the library can succeed later with the file
/// unchanged (F554): the disk was full, the share or drive it lives on went away, or the read timed
/// out. Such a failure says nothing about the file. Everything else — no permission, a corrupt file,
/// an error that gives no reason — is treated as the file's own, which is the importer's behaviour
/// for every copy failure before F554.
public enum ImportCopyFailure {
    /// POSIX reasons that describe the disk, the volume or the connection, never the file.
    /// `ENOENT` is here because a volume that unmounts mid-copy takes the path with it; a file
    /// that was deleted instead fails the same way on every retry, and the retry is bounded.
    static let transientPOSIXCodes: Set<Int> = [
        ENOSPC, EDQUOT, EIO, ENOENT, ENXIO, ENODEV, ESTALE, EAGAIN, EINTR,
        ENOTCONN, ETIMEDOUT, ENETDOWN, ENETUNREACH, ENETRESET, ECONNRESET, ECONNABORTED,
        EHOSTDOWN, EHOSTUNREACH,
    ].reduce(into: []) { $0.insert(Int($1)) }

    /// Cocoa codes that name one of those reasons themselves, for an error that carries no
    /// underlying POSIX error.
    static let transientCocoaCodes: Set<Int> = [
        NSFileWriteOutOfSpaceError, NSFileReadNoSuchFileError, NSFileNoSuchFileError,
    ]

    /// Foundation wraps the reason: a copy from a dropped share arrives as an unspecific Cocoa read
    /// error with the POSIX code under `NSUnderlyingErrorKey`, so the whole chain is read. Bounded,
    /// because nothing stops a user-info dictionary from pointing back at its own error.
    public static func isTransient(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        var depth = 0
        while let ns = current, depth < 8 {
            switch ns.domain {
            case NSPOSIXErrorDomain where transientPOSIXCodes.contains(ns.code):
                return true
            case NSCocoaErrorDomain where transientCocoaCodes.contains(ns.code):
                return true
            default:
                break
            }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }
}
