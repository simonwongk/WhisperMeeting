import Carbon
import CoreGraphics
import Foundation
import Testing
@testable import WhisperMeet

/// F489 — `CGEvent(virtualKey:)` names a key position, not a character; the app receiving it turns it
/// into a character through the current keyboard layout. The paste used position 9, which is V only
/// on QWERTY-shaped layouts: under ⌘ it types k on Dvorak (⌘K clears Terminal's scrollback, opens
/// Slack's switcher) and c on Turkish (⌘C copies over the dictation). Measured on this machine
/// (2026-09-25, `LMGetKbdType()` 91) over the 251 keyboard layouts macOS ships with 'uchr' data,
/// translating every key under ⌘: 246 have v at 9; Dvorak has it at 47, Dvorak-Right at 43, Turkish
/// and Turkish-Standard at 8; Turkmen has no v under ⌘ at all. The four these tests model:
///
///     com.apple.keylayout.US                 ⌘ v: [9]   key 9 under ⌘ types: v
///     com.apple.keylayout.Dvorak             ⌘ v: [47]  key 9 under ⌘ types: k
///     com.apple.keylayout.DVORAK-QWERTYCMD   ⌘ v: [9]   key 9 under ⌘ types: v   (plain v is at 47)
///     com.apple.keylayout.Russian            ⌘ v: [9]   key 9 under ⌘ types: v   (no plain v at all)
///
/// The translation is done WITH ⌘, which the last two lines make necessary: "Dvorak - QWERTY ⌘"
/// exists to put ⌘ shortcuts back on the QWERTY keys, and Russian has no v except under ⌘.
///
/// The first tests hand `UCKeyTranslate` a synthetic 'uchr' layout built from `UnicodeUtilities.h`,
/// so nothing depends on the layouts installed or selected on the machine running them; they are the
/// ones that must fail without the fix. The last feeds it Apple's own layouts where the host has
/// them, and says nothing where it does not.

/// A minimal 'uchr' keyboard layout: one keyboard-type entry (the default, 0...0), and two key
/// tables of 128 keys — one for no modifiers, one for ⌘ (modifier state 1, `cmdKey >> 8`). Every key
/// types nothing (0xFFFF) except those given.
private func syntheticLayout(plain: [UInt16: Character], command: [UInt16: Character]) -> Data {
    var data = Data()
    func u16(_ value: UInt16) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
    func u32(_ value: UInt32) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
    let tableSize = 128
    let headerSize = 12 + 28            // UCKeyboardLayout with one UCKeyboardTypeHeader
    let modifiersOffset = headerSize
    let modifiersSize = 12              // 8 + tableNum[2], padded to 4
    let indexOffset = modifiersOffset + modifiersSize
    let indexSize = 8 + 4 * 2           // UCKeyToCharTableIndex with two offsets
    let plainTableOffset = indexOffset + indexSize
    let commandTableOffset = plainTableOffset + tableSize * 2

    u16(0x1002); u16(0x0100); u32(0); u32(1)                   // kUCKeyLayoutHeaderFormat, v1.0, no feature info, 1 type
    u32(0); u32(0)                                             // the default keyboard-type entry
    u32(UInt32(modifiersOffset)); u32(UInt32(indexOffset)); u32(0); u32(0); u32(0)
    u16(0x3001); u16(0); u32(2); data.append(contentsOf: [0, 1, 0, 0]) // no modifiers → table 0, ⌘ → table 1
    u16(0x4001); u16(UInt16(tableSize)); u32(2); u32(UInt32(plainTableOffset)); u32(UInt32(commandTableOffset))
    for table in [plain, command] {
        for key in 0..<UInt16(tableSize) {
            u16(table[key].flatMap { $0.utf16.first } ?? 0xFFFF)
        }
    }
    return data
}

private let v: UInt16 = 0x76 // "v"
private let keyboardType: UInt32 = 40 // any: the synthetic layout has only the default entry

@Test("The paste uses the key that types v under ⌘ on the layout in use (F489)")
func pasteKeyFollowsTheLayout() {
    // Dvorak: V's QWERTY position (9) is k, and v is where QWERTY has "." (47), with or without ⌘.
    let dvorak = syntheticLayout(plain: [9: "k", 47: "v"], command: [9: "k", 47: "v"])
    #expect(TextInjector.keyCode(typing: v, withCommandIn: dvorak, keyboardType: keyboardType) == 47)

    // QWERTY: position 9.
    let qwerty = syntheticLayout(plain: [9: "v", 47: "."], command: [9: "v", 47: "."])
    #expect(TextInjector.keyCode(typing: v, withCommandIn: qwerty, keyboardType: keyboardType) == 9)
}

@Test("The ⌘ layer decides, not the plain one (F489)")
func pasteKeyIsReadUnderCommand() {
    // "Dvorak - QWERTY ⌘": Dvorak when typing, QWERTY while ⌘ is held. Reading the plain layer would
    // pick 47, which under ⌘ is "." — ⌘. is Cancel in most apps.
    let dvorakQwertyCommand = syntheticLayout(plain: [9: "k", 47: "v"], command: [9: "v", 47: "."])
    #expect(TextInjector.keyCode(typing: v, withCommandIn: dvorakQwertyCommand, keyboardType: keyboardType) == 9)

    // A layout with no v under ⌘ at all has no answer, so the caller can try another.
    let noV = syntheticLayout(plain: [9: "м"], command: [9: "м"])
    #expect(TextInjector.keyCode(typing: v, withCommandIn: noV, keyboardType: keyboardType) == nil)
}

/// The 'uchr' data of one installed keyboard layout, enabled or not, by input-source ID. Nil when
/// this host does not have it (a runner without a login session, a macOS that dropped the layout),
/// so the assertion that uses it is skipped rather than made about the machine.
private func installedLayoutData(_ inputSourceID: String) -> Data? {
    let filter = [kTISPropertyInputSourceID as String: inputSourceID] as CFDictionary
    guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue(), CFArrayGetCount(list) > 0 else {
        return nil
    }
    let source = unsafeBitCast(CFArrayGetValueAtIndex(list, 0), to: TISInputSource.self)
    guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
    return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
}

@Test("Apple's own layouts, where this host has them, agree with the synthetic ones (F489)")
func pasteKeyOnInstalledAppleLayouts() {
    // What each layout maps ⌘v to is a property of Apple's layout file, not of the host; only
    // whether the file is here is. The keyboard type is the host's, as in production — the letter
    // keys do not differ between the ANSI, ISO and JIS entries of these layouts.
    let expectations: [(id: String, key: CGKeyCode)] = [
        ("com.apple.keylayout.US", 9),
        ("com.apple.keylayout.Dvorak", 47),
        ("com.apple.keylayout.DVORAK-QWERTYCMD", 9),
        ("com.apple.keylayout.Russian", 9),
    ]
    for (id, key) in expectations {
        guard let data = installedLayoutData(id) else { continue }
        let found = TextInjector.keyCode(typing: v, withCommandIn: data, keyboardType: UInt32(LMGetKbdType()))
        #expect(found == key, "\(id): expected \(key), got \(String(describing: found))")
    }
}

@Test("The synthesized paste asks the layout for its key (F489)")
func postCommandVResolvesItsKey() throws {
    let lines = try SourceAssertion.uncommentedLines("Sources/WhisperMeet/Dictation/TextInjector.swift")
    let start = try #require(lines.firstIndex { $0.text.contains("func postCommandV()") })
    let body = lines[start...].prefix { !$0.text.hasPrefix("    }") }.map(\.text).joined(separator: "\n")
    #expect(body.contains("commandVKeyCode()"))
    #expect(!body.contains("CGKeyCode = 9"))
}
