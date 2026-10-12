import Foundation

/// Keeps file-write failures in Swift's error flow. `FileHandle.write(_:)` raises an uncaught
/// Objective-C exception on failures, which bypasses recording recovery and terminates the app.
public enum ThrowingFileHandleIO {
    public static func write(_ data: Data, to handle: FileHandle) throws {
        try handle.write(contentsOf: data)
        // F929: counted only when a task is counting (a stop's finalize or rebuild, which a quit
        // may be waiting on). A write that never returns is never counted, which is the point.
        WriteProgress.current?.tick()
    }
}
