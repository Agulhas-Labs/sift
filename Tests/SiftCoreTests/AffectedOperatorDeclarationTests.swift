//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A changed operator declaration is never refused by `affected` with advice to build: no build records one, and the changed-files line says so once.
@Suite(.serialized, .temporaryDirectories)
struct AffectedOperatorDeclarationTests {
    static var package: String {
        """
        // swift-tools-version:5.9
        import PackageDescription

        let package = Package(name: "Lib", targets: [.target(name: "Lib")])
        """
    }

    static func source(tone: Int) -> String {
        """
        infix operator <~>

        public func <~> (lhs: Int, rhs: Int) -> Int { lhs + rhs + \(tone) }

        public func blend() -> Int { 0 }
        """
    }

    @Test
    func aChangedOperatorDeclarationIsNotSentToBuild() async throws {
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

        #expect(!answer.contains("semantic REFUSED"), "\(answer)")
        #expect(!answer.contains("build this target"), "\(answer)")
        #expect(answer.contains("Sources/Lib/Pick.swift — added or modified, 3 declarations (1 operator declaration, which the index store does not record, so no build answers for it)"), "\(answer)")
    }
}
