//
// Copyright © Agulhas Labs
//

import SwiftParser
import SwiftSyntax

/// How a digest member line lays out a signature too long for one line: wrapped at its parameter boundaries, and past a total bound cut at one with a count of what is left.
///
/// A member's parameter list is the one thing a caller needs from a digest, and a long signature is exactly the member whose list is worth having, so the list is never cut inside a parameter. Every line but the first is indented under the first parameter; the return clause ends the last one. When the list opens past the first line's width, the first line ends before the generic clause, a continuation line carries the clause — wrapped at its top-level parameters if it too is long — and the parameters follow it; a declaration too long to fit even that first line is cut there and counts every parameter as left off.
struct DigestSignatureLayout {
    /// The signature's lines, the first starting at the declaration and the rest aligned under its first parameter.
    let lines: [String]
    /// The parameters left off past `totalBound`, zero when the list is whole.
    let omitted: Int

    /// The width a line of a wrapped signature fills before the next parameter starts a new one.
    static var lineWidth: Int {
        SourceSlicer.signatureCap
    }

    /// The characters of signature a digest shows before it cuts the list at a parameter boundary.
    static var totalBound: Int {
        800
    }

    /// The indent of a continuation line when the parameter list opens past the first line's width.
    static var lateIndent: String {
        "    "
    }

    /// The layout of `signature`, or `nil` when it has no parameter list to wrap.
    init?(_ signature: String) {
        let bytes = Array(signature.utf8)
        let finder = ParameterClauseFinder(viewMode: .sourceAccurate)
        finder.walk(Parser.parse(source: signature + " {}"))
        guard let clause = finder.clause, clause.rightParen.presence == .present, !clause.parameters.isEmpty else {
            return nil
        }
        func text(_ from: AbsolutePosition, _ to: AbsolutePosition) -> String {
            String(bytes: bytes[min(from.utf8Offset, bytes.count) ..< min(to.utf8Offset, bytes.count)], encoding: .utf8) ?? ""
        }
        let prefix = text(AbsolutePosition(utf8Offset: 0), clause.leftParen.endPositionBeforeTrailingTrivia)
        let parameters = clause.parameters.map { parameter in
            text(parameter.positionAfterSkippingLeadingTrivia, parameter.trailingComma?.position ?? parameter.endPositionBeforeTrailingTrivia)
        }
        let closing = text(clause.rightParen.positionAfterSkippingLeadingTrivia, AbsolutePosition(utf8Offset: bytes.count))
        let generics = finder.generics.flatMap { $0.endPosition <= clause.leftParen.position ? $0 : nil }
        let head = text(AbsolutePosition(utf8Offset: 0), generics?.leftAngle.positionAfterSkippingLeadingTrivia ?? clause.leftParen.positionAfterSkippingLeadingTrivia)
        guard prefix.count <= Self.lineWidth || head.count <= Self.lineWidth else {
            omitted = parameters.count
            lines = [SourceSlicer.cut(head, at: Self.lineWidth), Self.lateIndent + Self.marker(omitted)]
            return
        }

        var shown = parameters.count
        if signature.count > Self.totalBound {
            var length = prefix.count
            shown = 0
            for parameter in parameters {
                length += (shown == 0 ? 0 : 2) + parameter.count
                guard length <= Self.totalBound else { break }
                shown += 1
            }
        }
        omitted = parameters.count - shown
        var pieces = parameters.prefix(shown).map { $0 + "," }
        if omitted > 0 {
            pieces.append(Self.marker(omitted))
        } else {
            pieces[pieces.count - 1] = parameters[parameters.count - 1] + closing
        }
        guard prefix.count > Self.lineWidth else {
            lines = Self.wrapped(pieces, after: prefix)
            return
        }

        // The list opens past the first line's width: the declaration up to its generic clause is the first line, and the clause and the list continue beneath.
        var genericLines = [Self.lateIndent + "("]
        if let generics {
            let opening = text(generics.leftAngle.positionAfterSkippingLeadingTrivia, clause.leftParen.endPositionBeforeTrailingTrivia)
            if Self.lateIndent.count + opening.count <= Self.lineWidth {
                genericLines = [Self.lateIndent + opening]
            } else {
                let genericPieces = generics.parameters.map { parameter in
                    text(parameter.positionAfterSkippingLeadingTrivia, parameter.trailingComma?.endPositionBeforeTrailingTrivia ?? clause.leftParen.endPositionBeforeTrailingTrivia)
                }
                genericLines = Self.wrapped(genericPieces, after: Self.lateIndent + "<")
            }
        }
        lines = [head] + genericLines.dropLast() + Self.wrapped(pieces, after: genericLines[genericLines.count - 1])
    }

    /// The count a cut list ends with, naming how many parameters were left off.
    private static func marker(_ omitted: Int) -> String {
        "… +\(omitted) param\(omitted == 1 ? "" : "s")"
    }

    /// `pieces` laid after `prefix`, each on the current line while it fits `lineWidth` and otherwise starting a line of its own under the first.
    private static func wrapped(_ pieces: [String], after prefix: String) -> [String] {
        let alignment = String(repeating: " ", count: prefix.count)
        var lines: [String] = []
        var current = prefix
        var currentIsEmpty = true
        for piece in pieces {
            if currentIsEmpty {
                current += piece
            } else if current.count + 1 + piece.count <= lineWidth {
                current += " " + piece
            } else {
                lines.append(current)
                current = alignment + piece
            }
            currentIsEmpty = false
        }
        lines.append(current)
        return lines
    }

    /// The one note a digest carries when a member line on it ends its list with a count, naming the call that serves the rest.
    static func cutNote(over lines: [String]) -> [String] {
        guard lines.contains(where: { $0.contains(/… \+\d+ params?/) }) else { return [] }
        return ["", "(a signature ending `… +N params` was cut at a parameter boundary past \(totalBound) characters, or before its list where the declaration alone passes \(lineWidth) — `digest <Type>.<member>` serves the member's whole source)"]
    }
}

private extension DigestSignatureLayout {
    /// The first parameter clause and generic parameter clause in a parsed signature, which are the declaration's own: attributes come before them and carry neither.
    final class ParameterClauseFinder: SyntaxVisitor {
        var clause: FunctionParameterClauseSyntax?
        var generics: GenericParameterClauseSyntax?

        override func visit(_ node: GenericParameterClauseSyntax) -> SyntaxVisitorContinueKind {
            if generics == nil {
                generics = node
            }
            return .skipChildren
        }

        override func visit(_ node: FunctionParameterClauseSyntax) -> SyntaxVisitorContinueKind {
            if clause == nil {
                clause = node
            }
            return .skipChildren
        }
    }
}
