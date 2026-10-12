//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A use of a function the by-name scan cannot see, its bare name handed on unapplied, that the build recorded in a file does not cancel a call written there since: the file still lists the new call as written since the build.
@Suite(.temporaryDirectories, .serialized)
struct WhereByNameSurplusMaskTests {
    /// A committed package built with an index store, one file of it referring to a function by its bare name alone.
    private static func makeBuiltRepo(sourceLocation: SourceLocation = #_sourceLocation) async throws -> URL {
        let root = try TestSources.makeTempRepo()
        #expect(try TemporaryDirectory.entries(containing: root.lastPathComponent) == [root.lastPathComponent], sourceLocation: sourceLocation)
        try TestSources.write(
            """
            // swift-tools-version:5.9
            import PackageDescription

            let package = Package(name: "Lib", targets: [.target(name: "Lib")])
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write("public enum Binary {\n    public static func path(invokedAs name: String) -> String {\n        name\n    }\n}\n", to: "Sources/Lib/Binary.swift", in: root)
        try TestSources.write(Self.aliasSource, to: "Sources/Lib/Alias.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        try await TestSources.swiftBuildSuspending(packageAt: root)
        return root
    }

    private static var aliasSource: String {
        "extension Binary {\n    public static func alias() -> (String) -> String {\n        path\n    }\n}\n"
    }

    /// The reference on line 3 stays where the build recorded it and a call is written on line 8: the scan counts the call alone, so the store's count is taken over the same shapes and the call is the one more.
    @Test
    func aNewCallBesideAnUnappliedBareReferenceIsWrittenSinceTheBuild() async throws {
        let root = try await Self.makeBuiltRepo()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try TestSources.write(Self.aliasSource + "\npublic func added() -> String {\n    Binary.path(invokedAs: \"added\")\n}\n", to: "Sources/Lib/Alias.swift", in: root)

        let answer = try await engine.lookup(symbol: "Binary.path", freshness: engine.ensureFresh())
        let rows = answer.split(separator: "\n").map(String.init)

        #expect(rows.contains { $0.contains("written since the build, by name: ") && $0.hasSuffix(":8") }, "\(answer)")
    }
}
