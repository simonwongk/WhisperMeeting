// Sources/WhisperMeet/Dictation/PasteboardSnapshot.swift
import AppKit
import WhisperCore

/// Every item on a pasteboard, with every representation of each, copied out as bytes so a
/// dictation paste can put the user's clipboard back after borrowing it (F425; read at paste time
/// since F516).
struct PasteboardSnapshot: Equatable, Sendable {
    struct Representation: Equatable, Sendable {
        let type: String
        let data: Data
    }

    /// One entry per pasteboard item, each keeping its representations in the item's own order:
    /// the first is the one a pasting app prefers, so order is part of the content.
    let items: [[Representation]]
    /// The pasteboard's `changeCount` when these items were current. While the live count still
    /// equals it, the pasteboard holds exactly this content.
    let changeCount: Int

    /// Why a pasteboard was not snapshotted. Each one means "do not restore", never "restore
    /// something else", so every case falls back to the pre-F425 behaviour of leaving the
    /// dictation on the clipboard.
    ///
    /// `UnsurfacedError`: a `Result` discriminator that goes to the diagnostic log by its raw
    /// value, never to the user — a skipped restore is not something they asked for or can act on.
    enum Refusal: String, UnsurfacedError, Equatable, Sendable {
        /// `pasteboardItems` was nil: the header's "error retrieving pasteboard items".
        case unreadable
        /// The source asked clipboard tools not to keep it (`doNotRetainTypes`).
        case doNotRetain
        /// A representation produced no data — a stale item, or a promise that could not be
        /// fulfilled. Restoring the rest would hand back a different clipboard than the user had.
        case incomplete
        /// The pasteboard changed while it was being read, so the items may mix two contents.
        case changedWhileReading
    }

    /// The nspasteboard.org markers a password manager or similar source adds to say clipboard
    /// tools should not keep this. Restoring it would also re-publish it as a new write under a new
    /// `changeCount`, and a source that clears its secret after a timeout only if the clipboard is
    /// still its own write would then leave it in place past the timeout the user chose. The
    /// markers are checked from the item types alone, before any bytes are read, so the secret is
    /// never copied into this process.
    static let doNotRetainTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
    ]

    /// Reads every item and representation. It can block while a promised representation —
    /// Universal Clipboard content from another device, or another app's lazily provided data — is
    /// produced; F516 reads it at paste time on the main actor anyway, as VoiceInk does, because
    /// that is the moment whose clipboard the user expects back.
    static func read(from pasteboard: NSPasteboard) -> Result<PasteboardSnapshot, Refusal> {
        let changeCount = pasteboard.changeCount
        guard let pasteboardItems = pasteboard.pasteboardItems else { return .failure(.unreadable) }
        let markedDoNotRetain = pasteboardItems.contains { item in
            item.types.contains { doNotRetainTypes.contains($0.rawValue) }
        }
        if markedDoNotRetain { return .failure(.doNotRetain) }

        var items: [[Representation]] = []
        for item in pasteboardItems {
            var representations: [Representation] = []
            for type in item.types {
                // NSPasteboardItem.h: an item made stale by a new owner "will return nil".
                guard let data = item.data(forType: type) else { return .failure(.incomplete) }
                representations.append(Representation(type: type.rawValue, data: data))
            }
            items.append(representations)
        }
        guard pasteboard.changeCount == changeCount else { return .failure(.changedWhileReading) }
        return .success(PasteboardSnapshot(items: items, changeCount: changeCount))
    }

    /// Fresh pasteboard items carrying this content, or nil if any representation is refused.
    ///
    /// Always new items, never the ones `read` saw. NSPasteboardItem.h: "Passing a pasteboard item
    /// that is already associated with a pasteboard into -writeObjects: causes an exception to be
    /// raised" — an Objective-C exception, which no Swift `catch` can see. Staging before the
    /// pasteboard is touched also means a refused type (`setData` returns NO for a string that is
    /// not a valid UTI) leaves the pasteboard as it was rather than half-written.
    func stagedItems() -> [NSPasteboardItem]? {
        var staged: [NSPasteboardItem] = []
        for representations in items {
            let item = NSPasteboardItem()
            for representation in representations {
                guard item.setData(
                    representation.data,
                    forType: NSPasteboard.PasteboardType(representation.type)
                ) else { return nil }
            }
            staged.append(item)
        }
        return staged
    }
}
