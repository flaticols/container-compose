// swift-tools-version: 6.0
//===----------------------------------------------------------------------===//
// container-compose — Docker Compose compatibility layer for Apple's `container`.
//
// Ships as a CLI plugin for `container` (invoked as `container compose ...`)
// and as a standalone `container-compose` binary. It parses a Compose file and
// orchestrates the stable public `container` CLI (Option A — no internal APIs).
//===----------------------------------------------------------------------===//

import PackageDescription

let package = Package(
    name: "container-compose",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "container-compose", targets: ["container-compose"]),
        .library(name: "ComposeKit", targets: ["ComposeKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "container-compose",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "ComposeKit",
            ],
            path: "Sources/container-compose"
        ),
        .target(
            name: "ComposeKit",
            dependencies: [
                .product(name: "Yams", package: "Yams")
            ],
            path: "Sources/ComposeKit"
        ),
        .testTarget(
            name: "ComposeKitTests",
            dependencies: ["ComposeKit"],
            path: "Tests/ComposeKitTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
