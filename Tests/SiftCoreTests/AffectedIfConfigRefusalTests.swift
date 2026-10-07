//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A changed declaration under an `#if` this build left out is refused by `affected` in the words `where` uses, not with advice to build a target that no build of this configuration compiles.
@Suite(.serialized, .temporaryDirectories)
struct AffectedIfConfigRefusalTests {
    static var package: String {
        """
        // swift-tools-version:5.9
        import PackageDescription

        let package = Package(name: "Lib", targets: [.target(name: "Lib")])
        """
    }

    static func source(tone: Int) -> String {
        """
        #if os(Linux)
        public func tone() -> Int { \(tone) }
        #endif

        public func blend() -> Int { 0 }
        """
    }

    @Test
    func aChangedDeclarationUnderAnUncompiledIfIsNotSentToBuild() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.package, to: "Package.swift", in: root)
        try TestSources.write(Self.source(tone: 1), to: "Sources/Lib/Pick.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        try TestSources.write(Self.source(tone: 2), to: "Sources/Lib/Pick.swift", in: root)
        try TestSources.commitAll(in: root, message: "change")
        try await TestSources.swiftBuildSuspending(packageAt: root)

        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        let answer = try await engine.affected(options: AffectedOptions(range: AffectedOptions.CommitRange(from: "HEAD~1", to: "HEAD")), freshness: freshness)

        #expect(answer.contains("no occurrence recorded in this build; the declaration is under #if os(Linux), which this build may not have compiled"), "\(answer)")
        #expect(!answer.contains("build this target"), "\(answer)")
    }
}
