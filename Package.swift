// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Nullwave",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Nullwave", targets: ["Nullwave"]),
        .executable(name: "nullwavectl", targets: ["NullwaveCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")
    ],
    targets: [
        .executableTarget(
            name: "Nullwave",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/DarkNoise",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        ),
        .executableTarget(name: "NullwaveCLI", path: "Sources/NullwaveCLI"),
        .testTarget(name: "NullwaveTests", dependencies: ["Nullwave"], path: "Tests/DarkNoiseTests")
    ]
)
