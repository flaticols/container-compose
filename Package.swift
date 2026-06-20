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
        // ComposeKit lives in its own repo, split into a runtime-agnostic core
        // (ComposeKit) and the `container` runtime layer (ComposeKitContainer).
        // Pinned to an exact tag — for a 0.0.x line every patch may break, and
        // `from:` would float up to <1.0.0. Bump this string when adopting a
        // newer ComposeKit. For local changes, use
        // `swift package edit ComposeKit --path ../ComposeKit`. See PACKAGING.md.
        .package(url: "https://github.com/flaticols/ComposeKit.git", exact: "0.0.2"),
    ],
    targets: [
        .executableTarget(
            name: "container-compose",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "ComposeKit", package: "ComposeKit"),
                .product(name: "ComposeKitContainer", package: "ComposeKit"),
            ],
            path: "Sources/container-compose"
        )
    ]
)
