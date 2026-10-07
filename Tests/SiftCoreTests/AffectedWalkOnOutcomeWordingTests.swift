//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins what the walk-on says of each changed file it was asked about: a file the cap reached is counted and named, the cap note says which walk hit it, and the lines stating the bound state the hops actually walked.
struct AffectedWalkOnOutcomeWordingTests {
    private static func row(_ id: Int64, _ path: String) -> SymbolRow {
        SymbolRow(
            id: id, fileID: id, path: path, module: "Lib", parentID: nil, kind: .function, name: "f\(id)()",
            line: 1, column: 1, endLine: 2, accessLevel: .internalLevel, isStatic: false, isStored: false,
            signature: "func f\(id)()", docSummary: nil, ifConfigCondition: nil, viewOutline: nil
        )
    }

    private static func test(_ path: String) -> TestDeclaration {
        TestDeclaration(symbol: TestSymbol(target: "LibTests", suite: "KettleTests", function: "boils()", style: .swiftTesting), path: path, line: 3)
    }

    /// Three files, each one hop past the bound from a test, and room to expand one declaration: the first reaches its test, the other two are not walked.
    @Test
    func everyFileTheCapReachesIsCountedAndNamedNotLeftOut() throws {
        let files = ["a.swift", "b.swift", "c.swift"]
        var roots: [String: [SymbolRow]] = [:]
        var hits: [Int64: [ResolvedWalkOn.Hit]] = [:]
        for (index, path) in files.enumerated() {
            let root = Self.row(Int64(index + 1), path)
            roots[path] = [root]
            hits[root.id] = [ResolvedWalkOn.Hit(enclosing: Self.row(Int64(index + 11), path), test: nil, state: .live, leadsOn: true)]
        }
        var walkOn = ResolvedWalkOn(hits: hits) { row in
            [ResolvedWalkOn.Hit(enclosing: row, test: Self.test("Tests/KettleTests.swift"), state: .live, leadsOn: false)]
        }
        var budget = 1

        let result = try walkOn.run(from: roots, depth: 1, budget: &budget)

        #expect(result.outcomes.count == 3)
        #expect(result.outcomes.map(\.capped) == [false, true, true])
        #expect(result.capped)
        let note = try #require(result.note(depth: 1))
        #expect(note.contains("3 changed files"))
        #expect(note.contains("b.swift not walked: cap"))
        #expect(note.contains("c.swift not walked: cap"))
        #expect(note.contains("a.swift at 2 hops"))
    }

    /// A file that reached no test says how far it was walked, so "reached none" is not read as the bound.
    @Test
    func aFileThatReachedNoTestSaysHowFarItWasWalked() throws {
        let root = Self.row(1, "a.swift")
        let middle = Self.row(2, "a.swift")
        var walkOn = ResolvedWalkOn(hits: [1: [ResolvedWalkOn.Hit(enclosing: middle, test: nil, state: .live, leadsOn: true)]]) { _ in [] }
        var budget = 10

        let result = try walkOn.run(from: ["a.swift": [root]], depth: 1, budget: &budget)

        #expect(result.outcomes.first?.described == "a.swift reached none (walked 2 hops)")
        #expect(result.furthest == 2)
    }

    /// The walk-on's own cap is named as the walk-on's, and says the bounded walk was complete.
    @Test
    func theCapNoteSaysWhichWalkHitTheCap() {
        let capped = ResolvedWalkOn.Result(reached: [], outcomes: [ResolvedWalkOn.Outcome(path: "a.swift", hop: nil, capped: true, through: 2)], capped: true)

        let note = capped.capNote(cap: 1500)

        #expect(note?.contains("walk-on past the bound") == true)
        #expect(note?.contains("bounded walk itself was complete") == true)
        #expect(ResolvedWalkOn.Result().capNote(cap: 1500) == nil)
    }

    /// The depth line and `diff`'s tests section say the walk went on toward a first test, not to it.
    @Test
    func theStatedBoundSaysTowardAndNotTo() {
        let depthLine = AffectedBlindSpots.depthLine(2, walkedOn: 2)

        #expect(depthLine.contains("walked on past it toward each one's first test"))
        #expect(!depthLine.contains("walked on to each one's first test"))
        #expect(AffectedBlindSpots.walkedOnClause(1).contains("toward its first test as far as `sift affected` says it went"))
        #expect(AffectedBlindSpots.walkedOnClause(0).isEmpty)
    }

    /// `--reached` names the hops the walk-on actually walked, not only the bound.
    @Test
    func aProbeThatFoundNothingStatesTheHopsWalkedOn() {
        let walkedOn = AffectedProbe.lines(for: "Nope", reached: [], members: [:], depth: 2, walkedTo: 5).joined(separator: "\n")
        #expect(walkedOn.contains("not reached within 2 reference hops, nor within the 5 hops the walk went on to"))
        let plain = AffectedProbe.lines(for: "Nope", reached: [], members: [:], depth: 2).joined(separator: "\n")
        #expect(plain.contains("not reached within 2 reference hops."))
    }
}
