//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// The remainder after the page groups by path across the whole of it, names extensions in a form `digest` takes, and sits exactly on the byte budget.
struct SearchRemainderShapeTests {
    private static func match(_ path: String, _ name: String, kind: String = "struct", line: Int = 1, endLine: Int? = nil) -> StructuralMatch {
        StructuralMatch(path: path, line: line, endLine: endLine ?? line + 1, kind: kind, qualifiedName: name, signature: "\(kind) \(name)")
    }

    private static func filler(_ count: Int) -> [StructuralMatch] {
        (0 ..< count).map { match("Sources/App/Page\($0).swift", "Page\($0)") }
    }

    private static func rendered(_ matches: [StructuralMatch], query: String = "kind:struct") throws -> String {
        let result = StructuralSearch.Result(matches: matches, filesScanned: matches.count)
        return try SearchRenderer.render(result: result, query: StructuralQuery(query))
    }

    @Test
    func aPathSeparatedByAnotherInTheRemainderIsPrintedOnce() throws {
        let rest = [
            Self.match("Sources/App/One.swift", "Alpha"),
            Self.match("Sources/App/Two.swift", "Beta"),
            Self.match("Sources/App/One.swift", "Gamma"),
        ]
        let answer = try Self.rendered(Self.filler(SearchRenderer.matchCap) + rest)

        #expect(answer.components(separatedBy: "Sources/App/One.swift:").count == 2, "\(answer)")
        #expect(answer.contains("Sources/App/One.swift: Alpha, Gamma"), "\(answer)")
        let one = try #require(answer.range(of: "Sources/App/One.swift: "))
        let two = try #require(answer.range(of: "Sources/App/Two.swift: "))
        #expect(one.lowerBound < two.lowerBound, "\(answer)")
    }

    @Test
    func extensionsOfOneTypeInTheRemainderCarryTheirLineRanges() throws {
        let rest = [
            Self.match("Sources/App/Where.swift", "WhereRenderer", kind: "extension", line: 40, endLine: 90),
            Self.match("Sources/App/Where.swift", "WhereRenderer", kind: "extension", line: 120, endLine: 130),
        ]
        let answer = try Self.rendered(Self.filler(SearchRenderer.matchCap) + rest, query: "kind:struct|extension")

        #expect(answer.contains("Sources/App/Where.swift: WhereRenderer (:40-90), WhereRenderer (:120-130)"), "\(answer)")
    }

    /// The remainder's size in bytes as the renderer counts it: every line from the header on, plus a newline each.
    private static func remainderSize(_ answer: String) -> Int {
        let lines = answer.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains("names only") }) else { return -1 }
        return lines[start...].reduce(0) { $0 + $1.utf8.count + 1 }
    }

    private static func withPaddedLast(_ pad: Int) -> [StructuralMatch] {
        let rest = (0 ..< 20).map { match("Sources/App/Rest.swift", "R\($0)") }
        return filler(SearchRenderer.matchCap) + rest + [match("Sources/App/Rest.swift", "Last" + String(repeating: "x", count: pad))]
    }

    @Test
    func aRemainderFillingTheBudgetWithItsHeaderPrintsNamesAndOneByteMoreKeepsTheTruncationLine() throws {
        let base = try Self.rendered(Self.withPaddedLast(0))
        let pad = SearchRenderer.remainderBudget - Self.remainderSize(base)
        let exact = try Self.rendered(Self.withPaddedLast(pad))
        let over = try Self.rendered(Self.withPaddedLast(pad + 1))

        #expect(pad > 0)
        #expect(Self.remainderSize(exact) == SearchRenderer.remainderBudget, "\(exact)")
        #expect(!exact.contains("truncated"), "\(exact)")
        #expect(over.contains("… truncated: 21 more matches"), "\(over)")
        #expect(!over.contains("names only"), "\(over)")
    }
}
