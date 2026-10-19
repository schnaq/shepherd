// swift-tools-version: 6.0
//
// ShepherdKit — the platform-independent core of Shepherd.
//
// Nothing in this package may import AppKit, SwiftUI, WebKit, Security or any other
// Apple-only framework: the app target owns all of those. Everything here must build and
// test headlessly with `swift test` (see Packages/ShepherdKit/README.md).

import PackageDescription

let package = Package(
    name: "ShepherdKit",
    platforms: [
        // On the Mac the package deliberately targets a lower floor than the app (macOS 27):
        // the domain logic is reusable and testable on any recent toolchain, and the app
        // declares its own, higher deployment target in project.yml. iOS has no such reason —
        // its only client is the iPhone companion (ADR 0044), so the floor *is* the phone's.
        .macOS("15.0"),
        .iOS("27.0"),
    ],
    products: [
        .library(name: "ShepherdCore", targets: ["ShepherdCore"]),
        .library(name: "GitHubKit", targets: ["GitHubKit"]),
        .library(name: "ShepherdPersistence", targets: ["ShepherdPersistence"]),
        .library(name: "ShepherdSync", targets: ["ShepherdSync"]),
    ],
    dependencies: [
        // GRDB 7.10+ ships SwiftPM support for Linux (community-supported) in addition to
        // all Apple platforms, which keeps `swift test` green on both CI runners.
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.0")
    ],
    targets: [
        .target(
            name: "ShepherdCore",
            resources: [.process("Resources")]
        ),
        .target(
            name: "GitHubKit",
            dependencies: ["ShepherdCore"]
        ),
        .target(
            name: "ShepherdPersistence",
            dependencies: [
                "ShepherdCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "ShepherdSync",
            dependencies: ["ShepherdCore", "GitHubKit", "ShepherdPersistence"]
        ),

        .testTarget(
            name: "ShepherdCoreTests",
            dependencies: ["ShepherdCore"]
        ),
        .testTarget(
            name: "GitHubKitTests",
            dependencies: ["GitHubKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "ShepherdPersistenceTests",
            dependencies: ["ShepherdPersistence"]
        ),
        .testTarget(
            name: "ShepherdSyncTests",
            dependencies: ["ShepherdSync"]
        ),
    ]
)
