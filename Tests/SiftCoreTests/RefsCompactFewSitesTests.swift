//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins a `--refs` sweep above the row-per-line cap listing a file that holds one or two of its sites as rows naming what encloses them, while a file with more keeps its compact line numbers.
@Suite(.temporaryDirectories, .serialized)
struct RefsCompactFewSitesTests {
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "refs-compact-few-sites") { root in
            try TestSources.write(
                """
                // swift-tools-version: 6.0
                import PackageDescription

                let package = Package(
                    name: "Lib",
                    targets: [.target(name: "Lib")]
                )
                """,
                to: "Package.swift",
                in: root
            )
            try TestSources.write("public struct Gizmo: Sendable {\n    public init() {}\n}\n", to: "Sources/Lib/Gizmo.swift", in: root)
            let crowd = (1 ... 41).map { "    let made\($0) = Gizmo()\n    _ = made\($0)\n" }.joined()
            try TestSources.write("public func stock() -> Int {\n\(crowd)    return 1\n}\n", to: "Sources/Lib/Crowd.swift", in: root)
            try TestSources.write("struct Depot {\n    func assemble() -> Int {\n        let made = Gizmo()\n        _ = made\n        return 1\n    }\n}\n", to: "Sources/Lib/Lone.swift", in: root)
            try TestSources.commitAll(in: root, message: "refs compact few sites fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// A file holding one site of a sweep past the row cap lists it as a row naming its enclosing function, and the crowded file stays compact.
    @Test
    func aLoneSiteInACompactSweepNamesWhatEnclosesIt() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Gizmo", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
            let lines = output.components(separatedBy: "\n")
            let heading = try #require(lines.firstIndex(of: "  Sources/Lib/Lone.swift (1):"), "\(output)")

            #expect(lines[heading + 1] == "    :3  assemble()  | let made = Gizmo()", "\(output)")
            #expect(lines.contains { $0.hasPrefix("  Sources/Lib/Crowd.swift (41): 2, 4, 6") }, "\(output)")
        }
    }
}
