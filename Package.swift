// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Nullwave",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Nullwave", targets: ["Nullwave"]),
        .executable(name: "nullwavectl", targets: ["NullwaveCLI"])
    ],
    targets: [
        .executableTarget(name: "Nullwave", path: "Sources/DarkNoise"),
        .executableTarget(name: "NullwaveCLI", path: "Sources/NullwaveCLI"),
        .testTarget(name: "NullwaveTests", dependencies: ["Nullwave"], path: "Tests/DarkNoiseTests")
    ]
)
