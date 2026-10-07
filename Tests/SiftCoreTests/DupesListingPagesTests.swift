//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// What the whole-tree `dupes` listing promises beyond its groups: copies first, test and preview code last, pages on an offset cursor, and the floors the caller moves.
struct DupesListingPagesTests {
    private typealias Fixture = DupesChainedGroupTests

    /// A pair of bodies alike in every name they call, the names their own.
    private static func pair(_ name: String, path: String? = nil, skeleton: [DeclarationFingerprint.ControlToken] = [], typeNames: Set<String> = []) -> [DeclarationFingerprint] {
        let callees = (1 ... 4).map { "\(name)Call\($0)" }
        return ["One", "Two"].map { side in
            Fixture.fingerprint(name + side, callees: callees, path: path.map { $0 + side + ".swift" }, skeleton: skeleton, typeNames: typeNames)
        }
    }

    private static func answer(_ fingerprints: [DeclarationFingerprint], _ options: DupesOptions = DupesOptions()) -> DupesAnswer {
        DupesSearch.answer(scope: [], fingerprints: fingerprints + Fixture.filler, filesScanned: fingerprints.count + 20, options: options)
    }

    /// Thirteen groups list ten, say how many are left and the offset that reaches them, and an offset past the end says so.
    @Test
    func groupsPageOnTheOffsetCursor() {
        let pairs = (0 ..< 13).flatMap { Self.pair("Paged\($0)") }

        let first = DupesRenderer.render(answer: Self.answer(pairs))
        let last = DupesRenderer.render(answer: Self.answer(pairs, DupesOptions(offset: 10)))
        let past = DupesRenderer.render(answer: Self.answer(pairs, DupesOptions(offset: 20)))

        #expect(first.contains("13 group(s) of near-duplicate bodies"))
        #expect(first.contains(", 1–10 listed"))
        #expect(first.contains("… truncated: 3 more groups — pass --offset 10"))
        #expect(last.contains(", 11–13 listed"))
        #expect(!last.contains("truncated:"))
        #expect(past.contains("offset 20 is past the last of 13 groups"))
    }

    /// A group of test code ranks after a production one however it would rank by size, `--tests` ranks them together, and `--no-tests` leaves the test code out and counts it.
    @Test
    func codeOfTestsRanksLastUnlessAsked() {
        let tests = Self.pair("Checked", path: "Tests/Depot/Checked").map { fingerprint in
            DeclarationFingerprint(
                declaration: StructuralMatch(path: fingerprint.declaration.path, line: 1, endLine: 60, kind: "func", qualifiedName: fingerprint.declaration.qualifiedName, signature: "func run()"),
                callees: fingerprint.callees,
                skeleton: [],
                typeNames: []
            )
        }
        let fingerprints = tests + Self.pair("Shipped")

        let ranked = Self.answer(fingerprints)
        let together = Self.answer(fingerprints, DupesOptions(testCode: .rankedWithTheRest))
        let leftOut = Self.answer(fingerprints, DupesOptions(testCode: .leftOut))

        #expect(ranked.groups.map(\.isTestOrPreview) == [false, true])
        #expect(DupesRenderer.render(answer: ranked).contains("test and preview code, ranked after the rest:"))
        #expect(together.groups.map(\.isTestOrPreview) == [true, false])
        #expect(leftOut.totalGroups == 1)
        #expect(leftOut.census.testCodeLeftOut == 2)
        #expect(DupesRenderer.render(answer: leftOut).contains("2 of test and preview code left out (--no-tests)"))
    }

    /// A small pair of copies — one control flow, one set of written types — ranks above a bigger group of bodies that only call alike.
    @Test
    func copiesRankFirst() {
        let copies = Self.pair("Copied", skeleton: [.guardToken, .returnToken], typeNames: ["URL"])
        let looser = Self.pair("Bigger").enumerated().map { offset, fingerprint in
            DeclarationFingerprint(
                declaration: StructuralMatch(path: fingerprint.declaration.path, line: 1, endLine: 80, kind: "func", qualifiedName: fingerprint.declaration.qualifiedName, signature: "func run()"),
                callees: fingerprint.callees,
                skeleton: offset == 0 ? [.ifToken, .returnToken] : [.forToken],
                typeNames: ["URL"]
            )
        }
        let found = Self.answer(looser + copies)

        #expect(found.groups.map(\.copies) == [.all, .none])
        #expect(DupesRenderer.render(answer: found).contains("2 declarations, one control flow and one set of written types"))
    }

    /// A body too short to share is not compared and is counted, and `--min` raises the overlap every pair must reach.
    @Test
    func theSizeFloorAndTheMinimumOverlapNarrowTheAudit() {
        let short = Self.pair("Short").map { fingerprint in
            DeclarationFingerprint(
                declaration: StructuralMatch(path: fingerprint.declaration.path, line: 1, endLine: 3, kind: "func", qualifiedName: fingerprint.declaration.qualifiedName, signature: "func run()"),
                callees: fingerprint.callees,
                skeleton: [],
                typeNames: []
            )
        }
        let partial = [
            Fixture.fingerprint("Gizmo", callees: (1 ... 6).map { "partial\($0)" }),
            Fixture.fingerprint("Widget", callees: (1 ... 8).map { "partial\($0)" }),
        ]

        let floored = Self.answer(short + partial)
        let raised = Self.answer(partial, DupesOptions(minimumOverlap: 0.9))

        #expect(floored.census.underSizeFloor == 2)
        #expect(floored.totalGroups == 1)
        #expect(raised.totalGroups == 0)
        #expect(DupesRenderer.render(answer: raised).contains("no pair of declarations reached 0.90 shared-callee overlap"))
    }

    /// A declaration close to one member of a group but not the other is in no group, and the answer counts it rather than dropping it silently.
    @Test
    func aDeclarationLeftOutOfEveryGroupIsCounted() {
        let left = Fixture.fingerprint("Depot", callees: (1 ... 6).map { "rare\($0)" })
        let middle = Fixture.fingerprint("Orchard", callees: (1 ... 9).map { "rare\($0)" })
        let right = Fixture.fingerprint("Catalogue", callees: (3 ... 11).map { "rare\($0)" })
        let found = Self.answer([left, middle, right])

        #expect(found.strays == 1)
        #expect(DupesRenderer.render(answer: found).contains("1 declaration(s) cleared the floors with a member of a group they could not join"))
    }

    /// A callee the tests name past the fan-out bound still proposes a pair of the production bodies naming it.
    @Test
    func callsFromTestsDoNotCrowdOutAProductionPair() {
        let bound = SimilarityScore.dupesFanOutBound
        let crowd = (0 ... bound).map { Fixture.fingerprint("Crowd\($0)", callees: ["listing", "crowd\($0)"], path: "Tests/Depot/Crowd\($0)Tests.swift") }
        let production = ["Kept", "Copy"].map { Fixture.fingerprint($0, callees: ["listing", "\($0)A", "\($0)B"]) }
        let compared = crowd + production

        #expect(DupesSearch.candidatePairs(among: compared).contains(DupesSearch.IndexPair(low: compared.count - 2, high: compared.count - 1)))
    }
}
