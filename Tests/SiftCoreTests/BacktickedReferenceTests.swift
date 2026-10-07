//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the reading side of a backticked name: a call, a search term and a test written with backticks reach the declaration by the same word the index stores it under.
@Suite(.temporaryDirectories)
struct BacktickedReferenceTests {
    private static var source: String {
        """
        public struct Tick {
            func `class`() {}
            func `default`() {}
            func plain() {
                self.`class`()
                `default`()
                let other: `Tick`? = nil
            }
        }
        """
    }

    /// With no index store, `where` falls back to name-matched call sites; a call written in backticks is one of them, whichever spelling the query uses.
    @Test
    func theSyntacticFallbackFindsACallWrittenInBackticks() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.source, to: "Sources/Lib/Lib.swift", in: root)
        try TestSources.commitAll(in: root, message: "backticked calls, unbuilt")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        for (query, line) in [("Tick.class", 5), ("Tick.`class`", 5), ("default", 6), ("Tick.`default`()", 6)] {
            let output = try await engine.lookup(symbol: query, freshness: freshness)
            #expect(output.contains("syntactic call sites"), "where \(query):\n\(output)")
            #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/Lib/Lib.swift:\(line)  in Tick.plain()"), "where \(query):\n\(output)")
        }
    }

    /// `search calls:` and `uses:` match a backticked call or type by its bare word, and a `name:` value written in backticks is unwrapped like a `where` query.
    @Test(arguments: [
        ("calls:class", ["Tick", "Tick.plain()"]),
        ("calls:`class`", ["Tick", "Tick.plain()"]),
        ("uses:default", ["Tick", "Tick.plain()"]),
        ("uses:Tick", ["Tick", "Tick.plain()"]),
        ("name:`default`", ["Tick.default()"]),
        ("name:`default`()", ["Tick.default()"]),
    ])
    func searchMatchesABacktickedNameByItsBareWord(query: String, expected: [String]) throws {
        let matches = try StructuralMatcher.matches(in: Self.source, path: "Sources/Lib/Lib.swift", query: StructuralQuery(query))

        #expect(matches.map(\.qualifiedName) == expected, "search \(query)")
    }

    /// A test function and an XCTest case written in backticks are inventoried under their bare names, and a generic case whose name is backticked still lends its tests rather than declaring them.
    @Test
    func backtickedTestsAreInventoriedByTheirBareNames() throws {
        let inventory = try TestInventoryTests.inventory([
            (
                "WidgetTests/Settle.swift",
                """
                import Testing

                struct DepotStoreTests {
                    @Test func `settles`() {}
                }
                """
            ),
            (
                "WidgetTests/Pump.swift",
                """
                import XCTest

                final class `GizmoTests`: XCTestCase {
                    func `testExample`() {}
                }

                class `BaseCase`<Item>: XCTestCase {
                    func testOne() {}
                }

                final class GadgetTests: BaseCase<Int> {}
                """
            ),
        ])
        let identifiers = Set(inventory.tests.map { "\($0.suite)/\($0.function)" })

        #expect(identifiers == ["DepotStoreTests/settles()", "GizmoTests/testExample()", "GadgetTests/testOne()"], "\(identifiers.sorted())")
    }

    /// The fingerprint recognises an XCTest method whose `test` prefix is written inside backticks.
    @Test
    func theFingerprintRecognisesABacktickedXCTestMethod() {
        let fingerprints = FingerprintScanner.fingerprints(
            in: """
            import XCTest

            final class GizmoTests: XCTestCase {
                func `testExample`() {
                    XCTAssertTrue(drain())
                }
            }
            """,
            path: "WidgetTests/Pump.swift"
        )

        #expect(fingerprints.first { $0.declaration.qualifiedName == "GizmoTests.testExample()" }?.isTest == true, "\(fingerprints.map(\.declaration.qualifiedName))")
    }
}
