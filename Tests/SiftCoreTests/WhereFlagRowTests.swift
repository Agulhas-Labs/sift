//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers two defects in a row's flag: the name line's count must not claim a label narrowing that dropped nothing, and the flag itself must land on the site it was raised for, not every site sharing its line.
@Suite(.temporaryDirectories)
struct WhereFlagRowTests {
    private static func lookup(_ symbol: String, declaring declarations: String, calling calls: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(declarations, to: "Sources/App/Types.swift", in: root)
        try TestSources.write(calls, to: "Sources/App/Calls.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: symbol, freshness: freshness)
    }

    /// A name whose declared initializer matches none of its sites, but drops none either, is flagged row by row with no false count on the name line.
    @Test
    func aNameLineCountsOnlyASiteActuallyDropped() async throws {
        let output = try await Self.lookup(
            "P.init",
            declaring: """
            struct P {
                let a: Int
            }
            extension P {
                init(a: Int, b: Int) {
                    self.a = a
                }
            }
            """,
            calling: """
            struct Calls {
                func one() { _ = P(a: 1) }
                func two() { _ = P(a: 1, b: 2) }
                func three() { _ = P(a: 3) }
                func four() { _ = P(a: 4) }
            }
            """
        )

        #expect(output.contains("\"P.init\" (4 call sites in 1 file"))
        #expect(!output.contains("with the labels"))
        let rows = WhereAnswerRepetitionTests.sitesOnePerLine(output).split(separator: "\n").map(String.init)
        let oneRow = try #require(rows.first { $0.contains("in Calls.one(") })
        let twoRow = try #require(rows.first { $0.contains("in Calls.two(") })
        let threeRow = try #require(rows.first { $0.contains("in Calls.three(") })
        let fourRow = try #require(rows.first { $0.contains("in Calls.four(") })

        #expect(oneRow.contains("(no declared init matches — compiler-written or inherited)"))
        #expect(!twoRow.contains("(no declared init matches — compiler-written or inherited)"))
        #expect(threeRow.contains("(no declared init matches — compiler-written or inherited)"))
        #expect(fourRow.contains("(no declared init matches — compiler-written or inherited)"))
    }

    /// Two calls on one line are flagged independently: the one matching a declared initializer carries no flag even though another site on its own line does, and the two rows do not fold together.
    @Test
    func twoSitesOnOneLineAreFlaggedBySiteNotByLine() async throws {
        let output = try await Self.lookup(
            "P.init",
            declaring: """
            struct P {
                let a: Int
            }
            extension P {
                init(a: Int, b: Int) {
                    self.a = a
                }
            }
            """,
            calling: """
            struct Pair {
                let q = (P(a: 1, b: 2), P(a: 1))
            }
            """
        )

        let rows = WhereAnswerRepetitionTests.sitesOnePerLine(output).split(separator: "\n").map(String.init).filter { $0.contains("in Pair.q") }
        #expect(rows.count == 2)
        let matching = try #require(rows.first { !$0.contains("(no declared init matches — compiler-written or inherited)") })
        let unmatched = try #require(rows.first { $0.contains("(no declared init matches — compiler-written or inherited)") })
        #expect(matching != unmatched)
    }
}
