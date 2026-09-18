// swift-tools-version: 6.1
// F232's two-runtime probe. Not part of the app's package: it is built on demand, against the same
// pinned FluidAudio the app uses, and prints speaker counts and timings only — never audio content.
//
//     swift build -c release --package-path Scripts/bench/diarization/runtime-probe
//     …/runtime-probe/.build/release/probe <meeting.wav> <Runtime/Diarization/models> <sortformer cache dir>
//     …/runtime-probe/.build/release/sweep <Runtime/Diarization/models> <out dir> <thresholds,comma> <wav>…
import PackageDescription

let package = Package(
    name: "probe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.7", traits: [])
    ],
    targets: [
        .executableTarget(name: "probe", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
        // F225: one embedding pass per file, then a re-cluster per threshold.
        .executableTarget(name: "sweep", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
    ]
)
