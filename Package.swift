// swift-tools-version: 6.2
//
// Why 6.2 and not 6.0 (F216): the `traits:` argument on a package dependency does not exist before
// SwiftPM 6.1 — at 6.0 the manifest fails to compile with
// `error: 'package(url:exact:traits:)' is unavailable`. Without `traits: []` FluidAudio enables its
// default trait, which links NemoTextProcessing — a prebuilt Rust staticlib this app never calls
// (it is text normalisation for TTS) — unconditionally into WhisperMeet. Opting out is the only
// reason the tools version moved; nothing else in this manifest depends on 6.1+ behaviour, and the
// bump was verified to leave the test count and the release binary unchanged before the dependency
// was added. `.macOS(.v15)` and `swiftLanguageModes: [.v5]` are deliberately unchanged.

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
            dependencies: ["WhisperCore"]
        ),
        .testTarget(
            name: "WhisperMeetTests",
            dependencies: ["WhisperCore", "WhisperMeet"]
        )
    ],
    swiftLanguageModes: [.v5]
)
