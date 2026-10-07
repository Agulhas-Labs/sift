//
// Copyright © Agulhas Labs
//

import Foundation
import SwiftParser
import SwiftSyntax

public extension SetAsideRecord.MutatedLine {
    /// A line that is one assignment of a bare identifier, `target = name`: the name it reads, and where its target stands in the line.
    struct BareAssignment: Equatable, Sendable {
        /// The identifier on the right-hand side, as written.
        public let name: String
        /// The target's byte range within the line, trailing space excluded.
        let target: Range<Int>

        /// What the line reads as once it is set aside: the store gone, the read kept.
        public var replacement: String {
            "_ = \(name)"
        }
    }

    /// Line `number` of the file `text` as a bare-identifier assignment, or `nil` for any other line.
    ///
    /// Only a statement that starts and ends on the line, whose right-hand side is one identifier and whose target is not already `_`, qualifies: a call, a member access, an operator, a literal, a declaration and a compound assignment (`+=`) all give `nil`, because setting those aside as `_ = name` would do more than remove the store. The file is read with the parser, so the first line of a statement that goes on to the next, a line that shares its statement with another, and a line that does not parse are `nil` as well.
    static func bareAssignment(inFile text: String, line number: Int) -> BareAssignment? {
        let tree = Parser.parse(source: text)
        let converter = SourceLocationConverter(fileName: "", tree: tree)
        var touching: [CodeBlockItemSyntax] = []
        collectItems(Syntax(tree), converter: converter, line: number, into: &touching)
        guard touching.count == 1,
              let candidate = touching.first,
              converter.location(for: candidate.positionAfterSkippingLeadingTrivia).line == number,
              converter.location(for: candidate.endPositionBeforeTrailingTrivia).line == number,
              !candidate.hasError,
              let sequence = candidate.item.as(SequenceExprSyntax.self),
              sequence.elements.count == 3
        else {
            return nil
        }
        let elements = Array(sequence.elements)
        guard elements[1].is(AssignmentExprSyntax.self),
              !elements[0].is(DiscardAssignmentExprSyntax.self),
              let read = elements[2].as(DeclReferenceExprSyntax.self),
              read.argumentNames == nil,
              case .identifier = read.baseName.tokenKind
        else {
            return nil
        }
        let lineStart = converter.position(ofLine: number, column: 1).utf8Offset
        let start = elements[0].positionAfterSkippingLeadingTrivia.utf8Offset - lineStart
        let end = elements[0].endPositionBeforeTrailingTrivia.utf8Offset - lineStart
        guard start >= 0, start < end else {
            return nil
        }
        return BareAssignment(name: read.baseName.trimmedDescription, target: start ..< end)
    }

    /// Every code-block item under `node` that starts or ends on `line`, outermost first.
    private static func collectItems(
        _ node: Syntax,
        converter: SourceLocationConverter,
        line: Int,
        into found: inout [CodeBlockItemSyntax]
    ) {
        if let item = node.as(CodeBlockItemSyntax.self) {
            let first = converter.location(for: item.positionAfterSkippingLeadingTrivia).line
            let last = converter.location(for: item.endPositionBeforeTrailingTrivia).line
            if first == line || last == line {
                found.append(item)
            }
        }
        for child in node.children(viewMode: .sourceAccurate) {
            collectItems(child, converter: converter, line: line, into: &found)
        }
    }
}
