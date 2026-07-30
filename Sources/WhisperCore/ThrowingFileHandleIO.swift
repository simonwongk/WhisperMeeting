import Foundation

/// Keeps file-write failures in Swift's error flow. `FileHandle.write(_:)` raises an uncaught
/// Objective-C exception on failures, which bypasses recording recovery and terminates the app.
public enum ThrowingFileHandleIO {
    public static func write(_ data: Data, to handle: FileHandle) throws {
        try handle.write(contentsOf: data)
    }
}
