//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A target no setting renames builds the module its name spells, in an XcodeGen spec and a SwiftPM package as in an `.xcodeproj`.
@Suite(.temporaryDirectories)
struct ModuleNameSpellingTests {
    private static func specResolver(target: String) throws -> ModuleResolver {
        let root = try TemporaryDirectory.make("module-spelling").appendingPathComponent("module-spelling")
        let spec = "name: Pair\ntargets:\n  \(target):\n    type: framework\n    platform: iOS\n    sources: [Sources/Kit]\n"
        try TestSources.write(spec, to: "project.yml", in: root)
        try TestSources.write("public struct Widget {}\n", to: "Sources/Kit/Widget.swift", in: root)
        return ModuleResolver(repoRoot: root, config: SiftConfig())
    }

    /// Measured against `xcodebuild -showBuildSettings`: the raw target name was resolved, a module nothing imports.
    @Test(arguments: [("My-Kit", "My_Kit"), ("3D", "_D"), ("Café Ünï", "Café_Ünï")])
    func anUnsetXcodeGenTargetIsSpeltAsTheBuildSpellsIt(target: String, module: String) throws {
        let resolver = try Self.specResolver(target: target)

        #expect(resolver.resolvedModule(for: "Sources/Kit/Widget.swift") == module)
    }

    /// Read as `My-Kit`, the app's `extension My_Kit.Widget` was marked as one that may extend another module's `Widget`.
    @Test
    func whereMarksNoExtensionThroughTheSpeltModule() async throws {
        let root = try TestSources.makeTempRepo()
        let spec = "name: Pair\ntargets:\n  My-Kit:\n    type: framework\n    platform: iOS\n    sources: [Sources/Kit]\n"
            + "  App:\n    type: application\n    platform: iOS\n    sources: [Sources/App]\n"
        try TestSources.write(spec, to: "project.yml", in: root)
        try TestSources.write("public struct Widget {}\n", to: "Sources/Kit/Widget.swift", in: root)
        try TestSources.write("import My_Kit\n\nextension My_Kit.Widget {\n    func app() {}\n}\n", to: "Sources/App/Touch.swift", in: root)
        try TestSources.commitAll(in: root, message: "hyphenated target")
        let engine = try SiftEngine(directory: root)
        let output = try await engine.lookup(symbol: "Widget", freshness: engine.ensureFresh())

        #expect(output.contains("  extension My_Kit.Widget — 1 members — Sources/App/Touch.swift:3-5"), "\(output)")
        #expect(!output.contains("may extend another module's Widget"), "\(output)")
        #expect(!output.contains("My-Kit"), "\(output)")
    }

    /// SwiftPM's c99name, measured with `swift package describe`: declared and conventional targets alike.
    @Test(arguments: [("3D", "_D"), ("Café-Ü", "Café_Ü"), ("x²", "x_")])
    func aSwiftPMTargetIsSpeltAsSwiftPMSpellsIt(target: String, module: String) throws {
        let root = try TemporaryDirectory.make("module-spelling-pm").appendingPathComponent("module-spelling-pm")
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "Pkg",
            targets: [
                .target(name: "\(target)", path: "Declared/\(target)"),
                .target(name: "\(target)Conv"),
            ]
        )
        """
        try TestSources.write(manifest, to: "Package.swift", in: root)
        try TestSources.write("struct Declared {}\n", to: "Declared/\(target)/A.swift", in: root)
        try TestSources.write("struct Conv {}\n", to: "Sources/\(target)/B.swift", in: root)
        let resolver = ModuleResolver(repoRoot: root, config: SiftConfig())

        #expect(resolver.module(for: "Declared/\(target)/A.swift") == module)
        #expect(resolver.module(for: "Sources/\(target)/B.swift") == module)
    }
}
