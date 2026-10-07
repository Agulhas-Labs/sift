//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the syntactic manifest read: literal target names and paths come out, computed values fall out silently.
///
/// This parser exists because the convention scan alone resolves ZERO modules on a repo whose targets all declare explicit `path:` values in a tool-first layout (`<Tool>/Sources/<Tool>`), and the failure reads as "repo has no build files" rather than "the manifest was never consulted".
struct SwiftPMManifestTests {
    @Test
    func allSourceBearingTargetKindsAreExtractedWithTheirExplicitPaths() {
        let manifest = SwiftPMManifest.parse(source: """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "VendorTools",
            targets: [
                .target(name: "VendorToolsKit", path: "VendorToolsKit/Sources/VendorToolsKit"),
                .testTarget(name: "VendorToolsKitTests", path: "VendorToolsKit/Tests/VendorToolsKitTests"),
                .executableTarget(name: "Linter", path: "Linter/Sources/Linter"),
                .macro(name: "ToolMacros", path: "Macros/ToolMacros"),
            ]
        )
        """)

        #expect(manifest.targets == [
            SwiftPMManifest.Target(name: "VendorToolsKit", path: "VendorToolsKit/Sources/VendorToolsKit"),
            SwiftPMManifest.Target(name: "VendorToolsKitTests", path: "VendorToolsKit/Tests/VendorToolsKitTests"),
            SwiftPMManifest.Target(name: "Linter", path: "Linter/Sources/Linter"),
            SwiftPMManifest.Target(name: "ToolMacros", path: "Macros/ToolMacros"),
        ])
        // The test targets are kept apart as well as among them: only `.testTarget` builds a bundle a
        // `swift test` owes a closing count from (``RunTestBundles``).
        #expect(manifest.testTargets == ["VendorToolsKitTests"])
    }

    /// A conventional target still appears — with no path — so a manifest mixing both styles is read whole.
    @Test
    func aTargetWithoutAnExplicitPathHasANilPath() {
        let manifest = SwiftPMManifest.parse(source: """
        let package = Package(name: "Lib", targets: [.target(name: "Lib")])
        """)

        #expect(manifest.targets == [SwiftPMManifest.Target(name: "Lib", path: nil)])
    }

    /// Only literals are readable syntactically: a computed path degrades to nil, a computed name drops the target.
    @Test
    func computedValuesDegradeInsteadOfGuessing() {
        let manifest = SwiftPMManifest.parse(source: """
        let base = "Custom"
        let package = Package(name: "Lib", targets: [
            .target(name: "Fixed", path: base + "/Fixed"),
            .target(name: "Interpolated", path: "\\(base)/Interpolated"),
            .target(name: base),
        ])
        """)

        #expect(manifest.targets == [
            SwiftPMManifest.Target(name: "Fixed", path: nil),
            SwiftPMManifest.Target(name: "Interpolated", path: nil),
        ])
    }

    /// `binaryTarget` and `systemLibrary` carry no Swift source to map, and product/package calls are not targets.
    @Test
    func nonSourceFactoriesAreIgnored() {
        let manifest = SwiftPMManifest.parse(source: """
        let package = Package(
            name: "Lib",
            dependencies: [.package(name: "Dep", url: "https://example.com/dep", from: "1.0.0")],
            targets: [
                .binaryTarget(name: "Blob", path: "Blob.xcframework"),
                .systemLibrary(name: "CThing", path: "CThing"),
            ]
        )
        """)

        #expect(manifest.targets.isEmpty)
    }

    @Test
    func anUnreadableFileYieldsNoTargets() {
        let missing = URL(fileURLWithPath: "/nonexistent/Package.swift")

        #expect(SwiftPMManifest.parse(fileAt: missing).targets.isEmpty)
    }
}
