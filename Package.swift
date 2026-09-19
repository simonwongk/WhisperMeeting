// swift-tools-version: 6.1
//
// Why 6.1 and not 6.0 (F216): the `traits:` argument on a package dependency does not exist before
// SwiftPM 6.1 — at 6.0 the manifest fails to compile with
// `error: 'package(url:exact:traits:)' is unavailable`. Without `traits: []` FluidAudio enables its
// default trait, which links NemoTextProcessing — a prebuilt Rust staticlib this app never calls
// (it is text normalisation for TTS) — unconditionally into WhisperMeet. Opting out is the only
// reason the tools version moved; nothing else in this manifest depends on 6.1+ behaviour.
// `.macOS(.v15)` and `swiftLanguageModes: [.v5]` are deliberately unchanged.
//
// Why NOT 6.2 (F270): this line read 6.2 and broke CI on every push, because the `macos-15` runner
// ships Swift 6.1.0 — `error: package 'whispermeeting' is using Swift tools version 6.2.0 but the
// installed version is 6.1.0`, failing before a single test ran. It went unnoticed for months
// because the change sat unpushed; the first push after it exposed it. 6.1 is the real floor this
// manifest needs, and F216's own note above says so. Do not raise this line without checking what
// Swift the runner in `.github/workflows/quality.yml` actually has — a local toolchain is always
// newer and will not catch it.

import PackageDescription

let package = Package(
    name: "WhisperMeet",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "WhisperCore", targets: ["WhisperCore"]),
        .executable(name: "WhisperMeet", targets: ["WhisperMeet"])
    ],
    dependencies: [
        // Speaker diarization runtime (F216). `exact:` because this repo pins everything exactly and
        // FluidAudio's clustering semantics changed three times in the month before adoption.
        // `traits: []` drops the NemoTextProcessing linkage; see the tools-version note above. The
        // Rust xcframework is still DOWNLOADED at resolve time regardless — traits control linkage,
        // not fetching.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.7", traits: [])
    ],
    targets: [
        .target(
            name: "WhisperCore"
        ),
        .executableTarget(
            name: "WhisperMeet",
            // FluidAudio is imported ONLY here. `WhisperCore` stays Foundation-only (the purity rule
            // in AGENTS.md), which is exactly why the diarization runtime lives in the app target.
            dependencies: [
                "WhisperCore",
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("NaturalLanguage"),
                .linkedFramework("PDFKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Security"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .testTarget(
            name: "WhisperCoreTests",
            dependencies: ["WhisperCore"],
            // Read by source path (`#filePath`) in RefinementGuardVectorTests, never from a bundle;
            // excluded so SwiftPM stops warning that the JSON is an unhandled file.
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "WhisperMeetTests",
            dependencies: ["WhisperCore", "WhisperMeet"]
        )
    ],
    swiftLanguageModes: [.v5]
)
