//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import SwiftOperators
import SwiftSyntax
import Testing

/// Naming the shape of a slow expression, direct against a parsed tree rather than through a captured build.
struct BuildTimingExpressionShapeTests {
    /// The shape of the first `[…]` literal in `source`, folding sequence expressions the way a real build's tree is folded before naming.
    private static func shapeOfFirstArray(in source: String) -> String? {
        let (_, extra) = FileParser.parse(source: source, repoRelativePath: "Probe.swift") { tree, converter in (tree, converter) }
        let folded = OperatorTable.standardOperators.foldAll(extra.0) { _ in }
        let tree = folded.as(SourceFileSyntax.self) ?? extra.0
        guard let bracket = source.firstIndex(of: "[") else {
            return nil
        }
        let offset = source.utf8.distance(from: source.startIndex, to: bracket)
        let location = extra.1.location(for: AbsolutePosition(utf8Offset: offset))
        return BuildTimingExpressionShape.name(atLine: location.line, column: location.column, in: tree, converter: extra.1)
    }

    @Test
    func aHomogeneousLiteralWithANegativePrefixIsNotMixed() {
        #expect(Self.shapeOfFirstArray(in: "var offsets = [0, -1, 1]\n") == nil)
        #expect(Self.shapeOfFirstArray(in: "var scales = [1.0, -2.5]\n") == nil)
    }

    @Test
    func aTrulyMixedLiteralIsStillNamed() {
        #expect(Self.shapeOfFirstArray(in: "var values = [1, 2.5]\n") == "untyped mixed collection literal")
    }
}
