//
// Copyright © Agulhas Labs
//

import SwiftParser
import SwiftSyntax

/// The line one declaration's signature ends on, read from a parse of its file at answer time: the body's opening brace, or where there is no body, the last line of the head the index stores as its signature.
///
/// The index keeps a signature's text with its whitespace collapsed, so the text cannot say which line it ends on, and a scan of the source for a brace finds one in a trailing comment or a closure inside a stored value. The file is parsed for the one declaration asked about, and the tree is dropped before the extent returns.
struct SignatureExtent {
    let lastLine: Int

    /// The extent of `row`'s signature in `source`, the file's lines, or `nil` where no declaration of a kind with a signature starts where the row says it does.
    init?(of row: SymbolRow, in source: [String]) {
        let tree = Parser.parse(source: source.joined(separator: "\n"))
        let converter = SourceLocationConverter(fileName: row.path, tree: tree)
        let finder = DeclarationFinder(line: row.line, column: row.column, converter: converter)
        finder.walk(tree)
        guard let declaration = finder.found, let end = Self.end(of: declaration, named: row.name) else {
            return nil
        }
        lastLine = converter.location(for: end).line
    }

    /// Where the head of `declaration` ends: the body's opening brace, or the end of the head `SymbolVisitor` records as its signature.
    private static func end(of declaration: DeclSyntax, named name: String) -> AbsolutePosition? {
        if let function = declaration.as(FunctionDeclSyntax.self) {
            return function.body?.leftBrace.positionAfterSkippingLeadingTrivia
                ?? (function.genericWhereClause.map(Syntax.init) ?? Syntax(function.signature)).endPositionBeforeTrailingTrivia
        }
        if let initializer = declaration.as(InitializerDeclSyntax.self) {
            return initializer.body?.leftBrace.positionAfterSkippingLeadingTrivia
                ?? (initializer.genericWhereClause.map(Syntax.init) ?? Syntax(initializer.signature)).endPositionBeforeTrailingTrivia
        }
        if let subscriptDeclaration = declaration.as(SubscriptDeclSyntax.self) {
            return subscriptDeclaration.accessorBlock?.leftBrace.positionAfterSkippingLeadingTrivia
                ?? (subscriptDeclaration.genericWhereClause.map(Syntax.init) ?? Syntax(subscriptDeclaration.returnClause)).endPositionBeforeTrailingTrivia
        }
        if let variable = declaration.as(VariableDeclSyntax.self) {
            let binding = variable.bindings.first { $0.pattern.as(IdentifierPatternSyntax.self).map { SymbolNaming.name(of: $0.identifier) } == name } ?? variable.bindings.first
            return binding.map { $0.accessorBlock?.leftBrace.positionAfterSkippingLeadingTrivia ?? SymbolVisitor.variableHeadEnd(binding: $0) }
        }
        return nil
    }
}

private extension SignatureExtent {
    /// Finds the declaration that starts at one line and column, walking only the nodes that span that line.
    final class DeclarationFinder: SyntaxAnyVisitor {
        private let line: Int
        private let column: Int
        private let converter: SourceLocationConverter
        private(set) var found: DeclSyntax?

        init(line: Int, column: Int, converter: SourceLocationConverter) {
            self.line = line
            self.column = column
            self.converter = converter
            super.init(viewMode: .sourceAccurate)
        }

        override func visitAny(_ node: Syntax) -> SyntaxVisitorContinueKind {
            guard found == nil else {
                return .skipChildren
            }
            let start = converter.location(for: node.positionAfterSkippingLeadingTrivia)
            guard start.line <= line, line <= converter.location(for: node.endPositionBeforeTrailingTrivia).line else {
                return .skipChildren
            }
            if start.line == line, start.column == column, let declaration = node.as(DeclSyntax.self) {
                found = declaration
                return .skipChildren
            }
            return .visitChildren
        }
    }
}
