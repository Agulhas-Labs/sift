//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// Past the page cap, `search` prints the remainder as names grouped by file when they fit a byte budget, and keeps the truncation line when they do not.
struct SearchRemainderNamesTests {
    /// `count` matches, `perFile` to a file, named `Gizmo<n>` in `Sources/App/Depot<file>.swift`.
    private static func matches(_ count: Int, perFile: Int = 1) -> [StructuralMatch] {
        (0 ..< count).map { index in
            StructuralMatch(path: "Sources/App/Depot\(index / perFile).swift", line: 1, endLine: 2, kind: "struct", qualifiedName: "Gizmo\(index)", signature: "struct Gizmo\(index)")
        }
    }

    private static func rendered(_ matches: [StructuralMatch], offset: Int = 0) throws -> String {
        let result = StructuralSearch.Result(matches: matches, filesScanned: matches.count)
        return try SearchRenderer.render(result: result, query: StructuralQuery("kind:struct"), offset: offset)
    }

    @Test
    func aRemainderUnderTheBudgetIsPrintedAsNamesGroupedByFileWithNoTruncationLine() throws {
        let cap = SearchRenderer.matchCap
        let answer = try Self.rendered(Self.matches(cap + 6, perFile: 2))

        #expect(answer.contains("6 more, names only (digest or offset \(cap) for their rows):"), "\(answer)")
        #expect(answer.contains("Sources/App/Depot\(cap / 2).swift: Gizmo\(cap), Gizmo\(cap + 1)"), "\(answer)")
        #expect(answer.contains("Sources/App/Depot\(cap / 2 + 2).swift: Gizmo\(cap + 4), Gizmo\(cap + 5)"), "\(answer)")
        #expect(!answer.contains("truncated"), "\(answer)")
    }

    @Test
    func aRemainderOverTheBudgetKeepsTheTruncationLine() throws {
        let cap = SearchRenderer.matchCap
        let extra = 500
        let answer = try Self.rendered(Self.matches(cap + extra))

        #expect(answer.contains("… truncated: \(extra) more matches — pass offset \(cap)"), "\(answer)")
        #expect(!answer.contains("names only"), "\(answer)")
    }

    @Test
    func aPageFromAnExplicitOffsetFollowsTheSameRule() throws {
        let cap = SearchRenderer.matchCap
        let small = try Self.rendered(Self.matches(cap + 10), offset: 5)
        let large = try Self.rendered(Self.matches(cap + 500), offset: 5)

        #expect(small.contains("5 more, names only (digest or offset \(cap + 5) for their rows):"), "\(small)")
        #expect(!small.contains("truncated"), "\(small)")
        #expect(large.contains("pass offset \(cap + 5)"), "\(large)")
    }
}
