import Foundation

/// Asks the drive to put a file's or folder's bytes on stable storage before Shrink deletes the
/// audio they replace (F795 final review). A full decode reads the page cache, so it proves the new
/// file is right but not that it would survive a power loss; the originals' unlinks might.
///
/// `F_FULLFSYNC`, not `fsync`, for the reason F276 measured: `fsync` leaves the data in the drive's
/// cache. Where a volume refuses `F_FULLFSYNC` (some network and FAT volumes), plain `fsync` is the
/// best that volume offers, and is used rather than giving up.
enum DurableFlush {
    static func flush(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        if fcntl(descriptor, F_FULLFSYNC) == -1, fsync(descriptor) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
