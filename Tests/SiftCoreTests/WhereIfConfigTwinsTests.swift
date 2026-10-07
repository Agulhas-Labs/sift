//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Two declarations of one name in the branches of an `#if`: `where` lists each with the condition that tells it apart, and the branch this build left without an occurrence is refused in words that claim no more than the store shows — never with advice to build it.
@Suite(.serialized, .temporaryDirectories)
struct WhereIfConfigTwinsTests {
    static var package: String {
        """
        // swift-tools-version:5.9
        import PackageDescription

        let package = Package(name: "Lib", targets: [.target(name: "Lib")])
        """
    }

    static var source: String {
        """
        #if os(macOS)
        public func flavor() -> String { "mac" }
        #else
        public func flavor() -> String { "other" }
        #endif

        #if os(Linux)
        public func tone() -> Int { 1 }
        #endif

        public func blend() -> String { flavor() }
        """
    }

    /// Built on macOS, the `#else` twin has no occurrence while its file has a unit: it is labelled after the `#if` it is the other branch of, refused as possibly not compiled by this build, and the compiled twin is answered.
    @Test
    func theElseTwinIsLabelledAndRefusedAsPossiblyNotCompiled() async throws {
        let root = try await Self.builtPackage()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let located = try await engine.lookup(symbol: "flavor", freshness: engine.ensureFresh())

        #expect(located.contains("Sources/Lib/Pick.swift:2  [#if os(macOS)]"), "\(located)")
        #expect(located.contains("Sources/Lib/Pick.swift:4  [#else of #if os(macOS)]"), "\(located)")
        let refusal = "no occurrence recorded in this build; the declaration is under #else of #if os(macOS), which this build may not have compiled"
        #expect(located.contains(refusal), "\(located)")
        #expect(!located.contains("build this target"), "\(located)")
        #expect(located.contains("callers of Lib.flavor()"), "\(located)")
    }

    /// A lone declaration under an `#if` this build left out is refused in the same words, naming its own condition, and counted unresolved in the header as a declaration without a unit is.
    @Test
    func aDeclarationUnderAnUncompiledIfNamesItsCondition() async throws {
        let root = try await Self.builtPackage()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let located = try await engine.lookup(symbol: "tone", freshness: engine.ensureFresh())

        #expect(located.contains("Sources/Lib/Pick.swift:8  [#if os(Linux)]"), "\(located)")
        #expect(located.contains("no occurrence recorded in this build; the declaration is under #if os(Linux), which this build may not have compiled"), "\(located)")
        #expect(!located.contains("build this target"), "\(located)")
        #expect(located.contains("fresh, 1 declaration not found in the store"), "\(located)")
    }

    private static func builtPackage() async throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(package, to: "Package.swift", in: root)
        try TestSources.write(source, to: "Sources/Lib/Pick.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        try await TestSources.swiftBuildSuspending(packageAt: root)
        return root
    }
}
