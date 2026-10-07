// swift-tools-version: 6.2
import PackageDescription

/// Swift 6 language mode + zero-warning builds for every target.
///
/// Unlike a shared library, this package is never consumed by an Xcode app as an external dependency, so `.treatAllWarnings(as: .error)` is safe to set in the manifest itself.
let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "Sift",
    // A dev tool that must run anywhere it is pointed at a checkout — including machines that trail the
    // latest OS — so the deployment floor stays low.
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "SiftCore",
            targets: ["SiftCore"]
        ),
        .executable(
            name: "sift",
            targets: ["SiftCLI"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // Pinned exactly: SwiftSyntax must track the toolchain deliberately, never drift (Docs/Design.md §8).
        .package(url: "https://github.com/apple/swift-syntax.git", exact: "603.0.2"),
        // XcodeGen project.yml is a module-mapping source (Docs/Design.md §2); Yams parses it.
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        // The semantic layer's index-store reader. No semver tags exist — the branch tracks the toolchain (Docs/Design.md §2/§8),
        // and Package.resolved pins the exact revision.
        .package(url: "https://github.com/apple/indexstore-db.git", branch: "release/6.3.1"),
    ],
    targets: [
        .target(
            name: "SiftCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftParserDiagnostics", package: "swift-syntax"),
                // Folds operator precedence so build-analysis can tell a real long literal chain from a left-associative parse tree.
                .product(name: "SwiftOperators", package: "swift-syntax"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "IndexStoreDB", package: "indexstore-db"),
            ],
            swiftSettings: strictSettings
        ),
        .target(
            name: "SiftMCP",
            dependencies: [
                "SiftCore",
            ],
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "SiftCLI",
            dependencies: [
                "SiftCore",
                "SiftMCP",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "SiftCoreTests",
            dependencies: [
                "SiftCore",
            ],
            resources: [
                .copy("Fixtures"),
            ],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "SiftMCPTests",
            dependencies: [
                "SiftMCP",
                "SiftCore",
                // The hook's advice gate lives in the CLI (it is the one consumer with a payload in hand),
                // and its wiring is pinned here — importable because the CLI is @main, not main.swift.
                "SiftCLI",
            ],
            resources: [
                .copy("Fixtures"),
            ],
            swiftSettings: strictSettings
        ),
    ]
)
