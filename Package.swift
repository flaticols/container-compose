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
        .executable(name: "container-compose", targets: ["container-compose"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // ComposeKit lives in its own repo. Tracking `main` until the first
        // tagged release; at release time pin a version (`from: "0.1.0"`). For
        // local changes against a working copy, use
        // `swift package edit ComposeKit --path ../ComposeKit` rather than
        // editing this line. See PACKAGING.md.
        .package(url: "https://github.com/flaticols/ComposeKit.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "container-compose",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "ComposeKit", package: "ComposeKit"),
            ],
            path: "Sources/container-compose"
        )
    ]
)
