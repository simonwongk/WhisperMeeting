import AppKit
import SwiftUI

/// The windows showing the meeting library — `ContentView` — as opposed to Settings or Keyboard
/// Shortcuts (F674).
///
/// Only a library window hosts the `.alert` that `report(_:)` relies on and the at-risk banner
/// (F528), so "is a window readable" is the wrong question when the only readable window is
/// Settings: a message would wait, unseen, for a library window to open. Registered by the view
/// itself rather than recognised by window identifier, because SwiftUI owns those identifiers (it
/// uses them for state restoration) and names them as it likes.
@MainActor
enum LibraryWindowRegistry {
    private static let windows = NSHashTable<NSWindow>.weakObjects()

    static func contains(_ window: NSWindow) -> Bool { windows.contains(window) }

    fileprivate static func add(_ window: NSWindow) { windows.add(window) }
    fileprivate static func remove(_ window: NSWindow) { windows.remove(window) }
}

/// Put in `ContentView`'s background: registers whichever window it is in.
struct LibraryWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { MarkerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class MarkerView: NSView {
        private weak var registered: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let registered, registered !== window { LibraryWindowRegistry.remove(registered) }
            registered = window
            if let window { LibraryWindowRegistry.add(window) }
        }
    }
}
