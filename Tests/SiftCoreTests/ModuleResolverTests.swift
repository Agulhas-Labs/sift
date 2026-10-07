//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the three module-mapping sources and their precedence by longest prefix.
@Suite(.temporaryDirectories)
struct ModuleResolverTests {
    private static func makeTree() throws -> URL {
        let root = try TemporaryDirectory.make("modules")
            .appendingPathComponent("modules")
        try TestSources.write("// swift-tools-version: 6.2\n", to: "Kit/Package.swift", in: root)
        try TestSources.write("struct A {}\n", to: "Kit/Sources/KitCore/A.swift", in: root)
        try TestSources.write("struct B {}\n", to: "Kit/Tests/KernelTests/B.swift", in: root)
        try TestSources.write(
            """
            name: GizmoApp
            targets:
              GizmoApp:
                type: application
                sources:
                  - path: Apps/GizmoApp
            """,
            to: "Apps/project.yml",
            in: root
        )
        try TestSources.write("struct C {}\n", to: "Apps/GizmoApp/C.swift", in: root)
        return root
    }

    @Test
    func swiftPMLayoutMapsSourcesAndTests() throws {
        let root = try Self.makeTree()
        let resolver = ModuleResolver(repoRoot: root, config: SiftConfig())

        #expect(resolver.module(for: "Kit/Sources/KitCore/A.swift") == "KitCore")
        #expect(resolver.module(for: "Kit/Tests/KernelTests/B.swift") == "KernelTests")
    }

    @Test
    func xcodeGenTargetsMapAppSources() throws {
        let root = try Self.makeTree()
        let resolver = ModuleResolver(repoRoot: root, config: SiftConfig())

        #expect(resolver.module(for: "Apps/GizmoApp/C.swift") == "GizmoApp")
    }

    @Test
    func configMapWinsAndUnknownFallsBackToTopDirectory() throws {
        let root = try Self.makeTree()
        var config = SiftConfig()
        config.moduleMap = ["Kit/Sources/KitCore": "Renamed"]
        let resolver = ModuleResolver(repoRoot: root, config: config)

        #expect(resolver.module(for: "Kit/Sources/KitCore/A.swift") == "Renamed")
        #expect(resolver.module(for: "Elsewhere/D.swift") == "Elsewhere")
    }

    /// The failure this pins: a manifest below the repo root whose targets all declare explicit `path:` values in a tool-first layout resolves ZERO modules if only the `Sources/<Target>` convention is scanned.
    ///
    /// Every kind matters here — `.target`, `.executableTarget` and `.testTarget` all fail uniformly under that reading.
    @Test
    func explicitTargetPathsInANonRootManifestResolveAsDeclared() throws {
        let root = try TemporaryDirectory.make("manifest-paths")
            .appendingPathComponent("manifest-paths")
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "VendorTools",
                targets: [
                    .target(name: "VendorToolsKit", path: "VendorToolsKit/Sources/VendorToolsKit"),
                    .testTarget(name: "VendorToolsKitTests", path: "VendorToolsKit/Tests/VendorToolsKitTests"),
                    .executableTarget(name: "Linter", path: "./Linter/Sources/Linter"),
                ]
            )
            """,
            to: "VendorTools/Package.swift",
            in: root
        )
        try TestSources.write("struct A {}\n", to: "VendorTools/VendorToolsKit/Sources/VendorToolsKit/A.swift", in: root)
        try TestSources.write("struct B {}\n", to: "VendorTools/VendorToolsKit/Tests/VendorToolsKitTests/B.swift", in: root)
        try TestSources.write("struct C {}\n", to: "VendorTools/Linter/Sources/Linter/C.swift", in: root)

        let resolver = ModuleResolver(repoRoot: root, config: SiftConfig())

        #expect(resolver.resolvedModule(for: "VendorTools/VendorToolsKit/Sources/VendorToolsKit/A.swift") == "VendorToolsKit")
        #expect(resolver.resolvedModule(for: "VendorTools/VendorToolsKit/Tests/VendorToolsKitTests/B.swift") == "VendorToolsKitTests")
        #expect(resolver.resolvedModule(for: "VendorTools/Linter/Sources/Linter/C.swift") == "Linter")
        #expect(resolver.unmappedManifests.isEmpty)
    }

    /// The fingerprint is stable across identical rebuilds and moves with every resolution input — manifest bytes and the config `moduleMap` — because it is what decides whether an existing index gets re-attributed.
    @Test
    func fingerprintTracksResolutionInputs() throws {
        let root = try TemporaryDirectory.make("fingerprint")
            .appendingPathComponent("fingerprint")
        try TestSources.write("// swift-tools-version: 6.0\n", to: "Package.swift", in: root)
        try TestSources.write("struct A {}\n", to: "Sources/Lib/A.swift", in: root)

        let first = ModuleResolver(repoRoot: root, config: SiftConfig()).fingerprint
        let again = ModuleResolver(repoRoot: root, config: SiftConfig()).fingerprint
        #expect(first == again)

        try TestSources.write("// swift-tools-version: 6.0\n// edited\n", to: "Package.swift", in: root)
        let editedManifest = ModuleResolver(repoRoot: root, config: SiftConfig()).fingerprint
        #expect(editedManifest != first)

        var config = SiftConfig()
        config.moduleMap = ["Sources/Lib": "Renamed"]
        let editedMap = ModuleResolver(repoRoot: root, config: config).fingerprint
        #expect(editedMap != editedManifest)
    }

    /// A manifest that contributes nothing must be named, never silent — otherwise "repo has no build files" and "the manifest could not be read" look identical, and a broken read goes undiagnosed.
    @Test
    func aManifestContributingNoMappingIsReported() throws {
        let root = try TemporaryDirectory.make("manifest-unmapped")
            .appendingPathComponent("manifest-unmapped")
        try TestSources.write(
            """
            let paths = ["Computed/Path"]
            let package = Package(name: "Opaque", targets: [.target(name: "Opaque", path: paths[0])])
            """,
            to: "Opaque/Package.swift",
            in: root
        )
        try TestSources.write("struct A {}\n", to: "Opaque/Computed/Path/A.swift", in: root)

        let resolver = ModuleResolver(repoRoot: root, config: SiftConfig())

        #expect(resolver.unmappedManifests == ["Opaque/Package.swift"])
    }
}
