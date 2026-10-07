//
// Copyright © Agulhas Labs
//

import Foundation
import SwiftParser
import SwiftSyntax

/// The lines each `import` declaration in a source file occupies — the lines a file digest's `imports:` line accounts for, since it lists every one of them, inside `#if` blocks too.
///
/// From one parse whose tree is discarded before the lines are returned (Docs/Design.md §2). An import's lines run from its first token to its last, so a comment above it is not one of them.
struct ImportLines {
    /// Every import declaration's lines in `source`, in source order.
    static func of(source: String) -> [ClosedRange<Int>] {
        let tree = Parser.parse(source: source)
        let visitor = Visitor(converter: SourceLocationConverter(fileName: "", tree: tree))
        visitor.walk(tree)
        return visitor.lines
    }
}

public extension SiftEngine {
    /// Whether any of `ranges` in the file at `path` overlaps an `import` declaration's lines, which the file's digest lists and a members answer does not, or `false` where the index holds no file there.
    func overlapsImports(_ ranges: [ClosedRange<Int>], inFile path: String) throws -> Bool {
        try WindowMembersAnswer(renderer: makeDigestRenderer()).overlapsImports(ranges, inFile: path)
    }
}

private extension ImportLines {
    final class Visitor: SyntaxVisitor {
        private let converter: SourceLocationConverter
        private(set) var lines: [ClosedRange<Int>] = []

        init(converter: SourceLocationConverter) {
            self.converter = converter
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
            let first = converter.location(for: node.positionAfterSkippingLeadingTrivia).line
            let last = converter.location(for: node.endPositionBeforeTrailingTrivia).line
            lines.append(first ... max(first, last))
            return .skipChildren
        }
    }
}
