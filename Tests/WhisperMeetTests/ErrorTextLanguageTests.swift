import Foundation
import Testing

// F783 — which language Foundation writes its error text in, for WhisperMeet.
//
// `ErrorPresentation.isBridgePlaceholder` recognises the bridge's "(OSStatus error -10868.)" by its
// English shape, and Foundation localises that shape (German "(OSStatus-Fehler -10868.)", Chinese
// "（OSStatus错误-10868。）"). Measured on 2026-10-17, with the app's own `Resources/Info.plist` in a
// probe bundle (`.claude/wave8/gates/f783-probe` in the closing lane's worktree):
//
// - launched with `-AppleLanguages (de)` and `(zh-Hans)`, `Bundle.main.preferredLocalizations` is
//   `["en"]` and every placeholder is English — Foundation follows the MAIN bundle's languages, and
//   a bundle that declares none gets its development language, English;
// - the same probe with `CFBundleLocalizations = [en, de, zh_CN]` added renders German and Chinese.
//
// So the English match holds for exactly as long as the app declares no languages. That is what
// this pins: a change that gives the app a localization has to revisit the placeholder detector
// first. A shape-free detector was measured as well, and is not a drop-in: "no description keys
// and no failure reason" also describes 30 of Foundation's real sentences, among them Cocoa 256
// "The file couldn't be opened." and 512 "The file couldn't be saved.", which it would discard.

@Test("The app declares no language, so Foundation's error text stays English for the placeholder detector (F783)")
func appDeclaresNoLanguageSoErrorTextStaysEnglish() throws {
    let plistData = try Data(contentsOf: SourceAssertion.url("Resources/Info.plist"))
    let plist = try #require(
        try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
    )
    for key in ["CFBundleLocalizations", "CFBundleDevelopmentRegion", "CFBundleAllowMixedLocalizations"] {
        #expect(plist[key] == nil,
                "Info.plist declares \(key): Foundation's error text may no longer be English, and ErrorPresentation's placeholder match is English (F783)")
    }

    // A `.lproj` copied into Contents/Resources localizes the main bundle just as the key does.
    let resources = SourceAssertion.url("Resources")
    let enumerator = try #require(FileManager.default.enumerator(at: resources, includingPropertiesForKeys: nil))
    let lproj = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "lproj" }
    #expect(lproj.isEmpty, "Resources ships \(lproj.map(\.lastPathComponent)) (F783)")
    let packaging = try String(contentsOf: SourceAssertion.url("Scripts/build-app.sh"), encoding: .utf8)
    #expect(!packaging.contains(".lproj"), "build-app.sh packages a .lproj (F783)")
}
