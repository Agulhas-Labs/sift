//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins `where --refs` on a protocol leaving each conformance line to the conformers block: counted in the sweep's heading and the verdict, not listed again, and the file still named by `--files`.
@Suite(.temporaryDirectories, .serialized)
struct WhereRefsConformanceFoldTests {
    /// A protocol with two conformers in a file that holds nothing else of it, and two uses in another.
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-refs-conformance-fold") { root in
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
            try TestSources.write(
                """
                public protocol Greeter {
                    func salute()
                }
                """,
                to: "Sources/Lib/Greeter.swift",
                in: root
            )
            try TestSources.write(
                """
                public struct Soldier: Greeter {
                    public func salute() {}
                }

                public struct Cadet: Greeter {
                    public func salute() {}
                }
                """,
                to: "Sources/Lib/Ranks.swift",
                in: root
            )
            try TestSources.write(
                """
                public func drill(greeter: Greeter) {
                    greeter.salute()
                }

                public func parade(_ first: Greeter) {}
                """,
                to: "Sources/Lib/Drill.swift",
                in: root
            )
            try TestSources.commitAll(in: root, message: "refs conformance fold fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// The heading keeps the full count and says how many are the conformances; no conformance row is printed and the conformers block still lists both.
    @Test
    func sweepCountsConformancesAndDoesNotListThem() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Greeter", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))

            #expect(output.contains("references to Lib.Greeter (4 in 2 files, 2 of them the conformances listed below):"), "\(output)")
            #expect(!output.contains("struct Soldier: Greeter {"), "\(output)")
            #expect(!output.contains("struct Cadet: Greeter {"), "\(output)")
            #expect(output.contains("  Lib.Soldier — struct — Sources/Lib/Ranks.swift:1-3 — direct\n"), "\(output)")
            #expect(output.contains("  Lib.Cadet — struct — Sources/Lib/Ranks.swift:5-7 — direct"), "\(output)")
        }
    }

    /// The rows of a file with a use are unchanged, and a file holding only conformances gets no heading in the sweep.
    @Test
    func otherRowsStayAndAConformanceOnlyFileHasNoHeading() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Greeter", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
            let sweep = try #require(output.components(separatedBy: "references to Lib.Greeter (").last)

            #expect(sweep.contains("Sources/Lib/Drill.swift (2):"), "\(sweep)")
            #expect(sweep.contains("| public func drill(greeter: Greeter) {"), "\(sweep)")
            #expect(sweep.contains("parade(_ first: Greeter)"), "\(sweep)")
            #expect(!sweep.contains("Sources/Lib/Ranks.swift ("), "\(sweep)")
        }
    }

    /// `--files` still names the file holding only conformances.
    @Test
    func filesStillListsTheConformanceOnlyFile() async throws {
        try await Self.fixture().withEngine { engine in
            let files = try await engine.lookup(symbol: "Greeter", freshness: engine.ensureFresh(), options: WhereOptions(filesOnly: true))

            #expect(files.contains("Sources/Lib/Ranks.swift"), "\(files)")
            #expect(files.contains("Sources/Lib/Drill.swift"), "\(files)")
        }
    }

    /// Under `--refs` the `used by` verdict carries the clause too, and still lists no rows.
    @Test
    func verdictUnderRefsCarriesTheClause() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Greeter", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))

            #expect(output.contains("used by Lib.Greeter: 4 references in 2 files, 2 of them the conformances listed below — "), "\(output)")
        }
    }

    /// A one-line conformer, an attribute-first one and a wrapped-clause one in a single file; the lines after the first are named by no row of the conformers block.
    private static func multilineFixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-refs-conformance-fold-multiline") { root in
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
            try TestSources.write("public protocol P {}\n", to: "Sources/Lib/P.swift", in: root)
            try TestSources.write("public struct One: P {}\n", to: "Sources/Lib/One.swift", in: root)
            try TestSources.write("@frozen\npublic struct F: P {}\n", to: "Sources/Lib/F.swift", in: root)
            try TestSources.write("public struct W:\n    P {}\n", to: "Sources/Lib/W.swift", in: root)
            try TestSources.commitAll(in: root, message: "refs conformance fold multiline fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// A clause not on its declaration's first line is named by no row of the conformers block, so it keeps its sweep row and is not counted in the heading; the one-line conformer is folded.
    @Test
    func aClauseOffTheFirstLineKeepsItsRow() async throws {
        try await Self.multilineFixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "P", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
            let sweep = try #require(output.components(separatedBy: "references to Lib.P (").last)

            #expect(sweep.hasPrefix("3 in 3 files, 1 of them the conformance listed below):"), "\(sweep)")
            #expect(sweep.contains("Sources/Lib/F.swift (1): 2") || sweep.contains("Sources/Lib/F.swift (1):\n    :2"), "\(sweep)")
            #expect(sweep.contains("Sources/Lib/W.swift (1): 2") || sweep.contains("Sources/Lib/W.swift (1):\n    :2"), "\(sweep)")
            #expect(!sweep.contains("Sources/Lib/One.swift ("), "\(sweep)")
        }
    }

    /// 46 conformers (the block lists 40) and 41 other files of uses: a conformer past the block's cap keeps its row, and a second page prints the remaining rows under an unchanged heading.
    private static func cappedFixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-refs-conformance-fold-capped") { root in
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
            try TestSources.write("public protocol P {}\n", to: "Sources/Lib/P.swift", in: root)
            for index in 0 ..< 46 {
                let name = String(format: "C%02d", index)
                try TestSources.write("public struct \(name): P {}\n", to: "Sources/Lib/\(name).swift", in: root)
            }
            for index in 0 ..< 41 {
                let name = String(format: "U%02d", index)
                try TestSources.write("public func use\(name)(_ value: P) {}\n", to: "Sources/Lib/\(name).swift", in: root)
            }
            try TestSources.commitAll(in: root, message: "refs conformance fold capped fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    @Test
    func conformersPastTheBlockCapStayAsRowsAndASecondPageKeepsTheHeading() async throws {
        try await Self.cappedFixture().withEngine { engine in
            let freshness = try await engine.ensureFresh()
            let first = try await engine.lookup(symbol: "P", freshness: freshness, options: WhereOptions(includeReferences: true))
            let heading = "references to Lib.P (87 in 87 files, 40 of them the conformances listed below):"
            let block = first.components(separatedBy: "conformers of P (").last?.components(separatedBy: "\n\n").first ?? ""
            let unlisted = (0 ..< 46).map { String(format: "C%02d", $0) }.filter { !block.contains("Lib.\($0) —") }

            #expect(unlisted.count == 6, "\(first)")
            #expect(first.contains(heading), "\(first)")
            for name in unlisted {
                #expect(first.contains("Sources/Lib/\(name).swift (1):"), "\(name)\n\(first)")
            }

            let second = try await engine.lookup(symbol: "P", freshness: freshness, options: WhereOptions(includeReferences: true, offset: 40))
            #expect(second.contains(heading), "\(second)")
            #expect(second.contains("Sources/Lib/U40.swift (1):"), "\(second)")
            let sweep = second.components(separatedBy: "references to Lib.P (").last?.components(separatedBy: "\n\n").first ?? ""
            #expect(!sweep.contains("Sources/Lib/C"), "\(second)")
        }
    }
}
