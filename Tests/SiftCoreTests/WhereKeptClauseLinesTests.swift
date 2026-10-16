//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A qualified name-only query asked with no store counts the reasons it kept a reference by line, as it counts the references kept, and a call-site query still counts sites.
@Suite(.temporaryDirectories)
struct WhereKeptClauseLinesTests {
    private static func answer(_ body: String, sourceLocation: SourceLocation = #_sourceLocation) async throws -> (line: String, output: String) {
        let source = """
        import SwiftUI

        struct Depot {
            static func of(_ count: Int) -> Int { count }
        }
        struct Orchard {
            func uses(_ xs: [Int]) {
        \(body)
            }
        }
        """
        let root = try TestSources.makeTempRepo()
        try TestSources.write(source, to: "Sources/App/Uses.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let output = try await CallSiteHeadingTests.lookup("Depot.of", in: root)
        let line = try #require(output.split(separator: "\n").first { $0.contains("the name is written") || $0.hasPrefix("\"of\" (") }, "\(output)", sourceLocation: sourceLocation)
        return (String(line), output)
    }

    /// Two references on one line count as one in the clause, as they do in the kept count, so the clause is never larger than the count it explains.
    @Test
    func twoReferencesOnOneLineAreOneInTheClause() async throws {
        let (line, output) = try await Self.answer("        _ = xs.map(Thing.of) + xs.map(Thing.of)")

        #expect(line.contains("written once with no call"), "\(output)")
        #expect(line.contains("1 on types the tree does not declare (Thing ×1)"), "\(output)")
    }

    /// Two references on two lines are two in the clause.
    @Test
    func twoReferencesOnTwoLinesAreTwoInTheClause() async throws {
        let (line, output) = try await Self.answer("        _ = xs.map(Thing.of)\n        _ = xs.map(Thing.of)")

        #expect(line.contains("written 2 times with no call"), "\(output)")
        #expect(line.contains("2 on types the tree does not declare (Thing ×2)"), "\(output)")
    }

    /// Two calls on one line are two sites, and the clause counts them so.
    @Test
    func callsOnOneLineStillCountBySite() async throws {
        let (line, output) = try await Self.answer("        _ = Thing.of(1) + Thing.of(2)")

        #expect(line.contains("2 on types the tree does not declare (Thing ×2)"), "\(output)")
    }
}
