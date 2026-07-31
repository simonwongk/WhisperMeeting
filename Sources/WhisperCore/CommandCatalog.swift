import Foundation

/// The app state a keyboard command's enablement depends on. Framework-free so the catalog is
/// testable without SwiftUI (F69).
public struct AppCommandState: Sendable, Equatable {
    public let isRecording: Bool
    public let isTranscribing: Bool

    public init(isRecording: Bool, isTranscribing: Bool = false) {
        self.isRecording = isRecording
        self.isTranscribing = isTranscribing
    }
}

public struct CommandModifiers: OptionSet, Sendable, Equatable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let control = CommandModifiers(rawValue: 1 << 0)
    public static let option = CommandModifiers(rawValue: 1 << 1)
    public static let shift = CommandModifiers(rawValue: 1 << 2)
    public static let command = CommandModifiers(rawValue: 1 << 3)
}

/// When a command is available, as a value (so `AppCommand` stays a plain, testable value).
public enum CommandEnablement: Sendable, Equatable {
    case always
    case whileRecording
    case whileIdle // not recording and not transcribing

    public func isEnabled(_ state: AppCommandState) -> Bool {
        switch self {
        case .always: return true
        case .whileRecording: return state.isRecording
        case .whileIdle: return !state.isRecording && !state.isTranscribing
        }
    }
}

public struct AppCommand: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let section: String
    public let keyEquivalent: Character?
    public let modifiers: CommandModifiers
    public let enablement: CommandEnablement

    public init(
        id: String, title: String, section: String,
        keyEquivalent: Character?, modifiers: CommandModifiers, enablement: CommandEnablement
    ) {
        self.id = id
        self.title = title
        self.section = section
        self.keyEquivalent = keyEquivalent
        self.modifiers = modifiers
        self.enablement = enablement
    }
}

/// The app's keyboard commands, in one place so shortcuts can't silently collide and a shortcuts
/// sheet can render from a single source (F69).
public enum CommandCatalog {
    public static let all: [AppCommand] = [
        AppCommand(id: "toggleRecording", title: "Start / Stop Recording", section: "Recording",
                   keyEquivalent: "r", modifiers: [.command], enablement: .always),
        AppCommand(id: "addMarker", title: "Add Marker", section: "Recording",
                   keyEquivalent: "m", modifiers: [.shift, .command], enablement: .whileRecording),
        AppCommand(id: "cancelRecording", title: "Cancel Recording…", section: "Recording",
                   keyEquivalent: nil, modifiers: [], enablement: .whileRecording),
        AppCommand(id: "keyboardShortcuts", title: "Keyboard Shortcuts", section: "Help",
                   keyEquivalent: "/", modifiers: [.command], enablement: .always),
    ]

    /// The display shortcut (e.g. "⇧⌘M"), or nil when the command has no key equivalent. Modifier
    /// symbols follow macOS order (⌃⌥⇧⌘).
    public static func displayShortcut(for command: AppCommand) -> String? {
        guard let key = command.keyEquivalent else { return nil }
        var symbols = ""
        if command.modifiers.contains(.control) { symbols += "⌃" }
        if command.modifiers.contains(.option) { symbols += "⌥" }
        if command.modifiers.contains(.shift) { symbols += "⇧" }
        if command.modifiers.contains(.command) { symbols += "⌘" }
        return symbols + String(key).uppercased()
    }
}
