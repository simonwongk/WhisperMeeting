// swift-tools-version: 6.0

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
    targets: [
        .target(
            name: "WhisperCore"
        ),
        .executableTarget(
            name: "WhisperMeet",
            dependencies: ["WhisperCore"],
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
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .testTarget(
            name: "WhisperCoreTests",
            dependencies: ["WhisperCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
