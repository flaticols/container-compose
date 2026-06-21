// swift-tools-version: 6.0
// container-compose — Docker Compose compatibility layer for Apple's `container`.
//
// Ships as a CLI plugin for `container` (invoked as `container compose ...`)
// and as a standalone `container-compose` binary. It parses a Compose file with
// ComposeKit and orchestrates the stable public `container` CLI (Option A — no
// internal APIs). The runtime layer (ContainerComposeKit) lives here; ComposeKit
// is the runtime-agnostic spec parser.

import PackageDescription

let package = Package(
    name: "container-compose",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "container-compose", targets: ["container-compose"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // ComposeKit is the runtime-agnostic Compose parser, in its own repo.
        // Pinned to an exact tag — for a 0.0.x line every patch may break, and
        // `from:` would float up to <1.0.0. Bump this string when adopting a
        // newer ComposeKit. For local changes, use
        // `swift package edit ComposeKit --path ../ComposeKit`. See PACKAGING.md.
        .package(url: "https://github.com/flaticols/ComposeKit.git", exact: "0.0.2"),
    ],
    targets: [
        // The `container` runtime layer: maps the parsed model onto `container`
        // run/build args and orchestrates up/down/ps/logs/exec/pull/stop/start.
        .target(
            name: "ContainerComposeKit",
            dependencies: [.product(name: "ComposeKit", package: "ComposeKit")],
            path: "Sources/ContainerComposeKit"
        ),
        .executableTarget(
            name: "container-compose",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "ComposeKit", package: "ComposeKit"),
                "ContainerComposeKit",
            ],
            path: "Sources/container-compose"
        ),
        .testTarget(
            name: "ContainerComposeKitTests",
            dependencies: [
                "ContainerComposeKit",
                .product(name: "ComposeKit", package: "ComposeKit"),
            ],
            path: "Tests/ContainerComposeKitTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
