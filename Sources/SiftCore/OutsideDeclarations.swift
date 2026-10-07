//
// Copyright © Agulhas Labs
//

import SwiftSyntax

/// Everything in one side of a file that no recorded declaration's own text covers, sorted into what a reviewer would call it — plus the exact text each recorded declaration is compared by.
///
/// `diff` compares declarations by their own text, and that text is deliberately narrow: from the first token to the last, no doc comment above and no comment trailing the closing brace. So a change can land in the file and in no declaration at all — an import, a `#if` condition, a comment between members or above a type, a `deinit`, a `#Preview`, top-level code. A review tool that let those read as "unchanged" would be worse than none, since the reader would never look; so every comment and stray token of the file lands somewhere here, with its lines, and whatever no named category claims lands in ``Category/other`` rather than nowhere. What is left — whitespace, and a type's own header and braces, which its signature carries — is checked by the line diff `FileDiff` holds every answer to.
struct OutsideDeclarations: Sendable {
    var fragments: [Category: [Fragment]] = [:]
    /// The text each recorded declaration is compared by, keyed by where the visitor recorded it.
    var ownText: [SymbolKey: String] = [:]
    /// The line each type's or extension's opening brace is on — where its header ends — keyed by where the visitor recorded it.
    var headerEnds: [SymbolKey: Int] = [:]
}

extension OutsideDeclarations {
    enum Category: CaseIterable, Sendable {
        case imports, conditions, comments, topLevelCode, deinitializers, macroExpansions, other
    }

    /// One piece of text outside every declaration: what it is called (where it has a name worth pairing by), its text, and the lines it spans.
    struct Fragment: Sendable, Equatable {
        let label: String?
        let text: String
        let line: Int
        let endLine: Int
    }

    /// Where the symbol visitor recorded a declaration — its start line and column, and its name where one declaration records several (`let a = 1, b = 2`, `case a, b`).
    struct SymbolKey: Hashable, Sendable {
        let line: Int
        let column: Int
        let name: String?
    }

    /// Walks one parsed file; the tree is the caller's and is not retained.
    static func of(_ tree: SourceFileSyntax, converter: SourceLocationConverter) -> OutsideDeclarations {
        let visitor = Visitor(converter: converter)
        visitor.walk(tree)
        return visitor.result
    }
}

private extension OutsideDeclarations {
    /// The walk behind ``OutsideDeclarations``: one region at a time, the outermost wins.
    ///
    /// A region is a node whose whole text belongs to one thing — a recorded declaration, an import, a `deinit`, a freestanding macro, a top-level statement, a type's header. Once a region is open, everything under it is its text (a comment inside a function body is the function's); outside every region, trivia is sorted piece by piece and a stray token is ``OutsideDeclarations/Category/other``. A type's header is the one region whose trivia is sorted too: its tokens are its signature, which the declaration diff compares, but a doc comment, a licence header or a `// MARK:` in front of it is text of its own.
    final class Visitor: SyntaxAnyVisitor {
        private let converter: SourceLocationConverter
        private(set) var result = OutsideDeclarations()
        private var region: Region?
        /// Trailing trivia of the region's latest token — its own text if another token of the region follows, between-text if the region ends on it.
        private var pendingTrailing = ""
        private var consumed: Set<SyntaxIdentifier> = []
        private var containers: [String] = []

        init(converter: SourceLocationConverter) {
            self.converter = converter
            super.init(viewMode: .sourceAccurate)
        }

        override func visitAny(_ node: Syntax) -> SyntaxVisitorContinueKind {
            if let token = node.as(TokenSyntax.self) {
                handle(token)
                return .skipChildren
            }
            if let region, case .containerHeader = region.kind, region.id == node.parent?.id, let block = node.as(MemberBlockSyntax.self) {
                recordHeaderEnd(of: node.parent, at: block)
                self.region = nil
            }
            guard region == nil else { return .visitChildren }
            if let name = Self.containerName(of: node) {
                containers.append(name)
            }
            if let clause = node.as(IfConfigClauseSyntax.self) {
                recordCondition(clause)
            } else if let block = node.as(IfConfigDeclSyntax.self) {
                recordEndif(block)
            }
            region = openRegion(at: node)
            return .visitChildren
        }

        override func visitAnyPost(_ node: Syntax) {
            if let open = region, open.id == node.id {
                close(open)
                region = nil
            }
            if region == nil, Self.containerName(of: node) != nil {
                containers.removeLast()
            }
        }
    }
}

private extension OutsideDeclarations.Visitor {
    struct Region {
        let id: SyntaxIdentifier
        let kind: Kind
        let line: Int
        let endLine: Int
        let firstToken: SyntaxIdentifier?
        let lastToken: SyntaxIdentifier?
        var text = ""
    }

    static func containerName(of node: Syntax) -> String? {
        if let decl = node.as(StructDeclSyntax.self) {
            return decl.name.text
        }
        if let decl = node.as(ClassDeclSyntax.self) {
            return decl.name.text
        }
        if let decl = node.as(ActorDeclSyntax.self) {
            return decl.name.text
        }
        if let decl = node.as(EnumDeclSyntax.self) {
            return decl.name.text
        }
        if let decl = node.as(ProtocolDeclSyntax.self) {
            return decl.name.text
        }
        if let decl = node.as(ExtensionDeclSyntax.self) {
            return decl.extendedType.trimmedDescription
        }
        return nil
    }

    /// The region a node opens when no region is open yet, or `nil` for a node that is only a path to its children.
    func openRegion(at node: Syntax) -> Region? {
        let kind: Region.Kind
        if node.is(FunctionDeclSyntax.self) || node.is(InitializerDeclSyntax.self) || node.is(SubscriptDeclSyntax.self)
            || node.is(TypeAliasDeclSyntax.self) || node.is(AssociatedTypeDeclSyntax.self) || node.is(MacroDeclSyntax.self)
            || node.is(OperatorDeclSyntax.self) || node.is(PrecedenceGroupDeclSyntax.self)
        {
            recordOwnText(of: node, entries: [(nil, node.trimmedDescription)])
            kind = .declaration
        } else if let variable = node.as(VariableDeclSyntax.self) {
            recordOwnText(of: node, entries: Self.ownTexts(of: variable))
            kind = .declaration
        } else if let cases = node.as(EnumCaseDeclSyntax.self) {
            recordOwnText(of: node, entries: Self.ownTexts(of: cases))
            kind = .declaration
        } else if Self.containerName(of: node) != nil {
            kind = .containerHeader
        } else if let decl = node.as(ImportDeclSyntax.self) {
            kind = .fragment(.imports, label: decl.path.trimmedDescription)
        } else if node.is(DeinitializerDeclSyntax.self) {
            kind = .fragment(.deinitializers, label: "deinit in \(containers.isEmpty ? "(top level)" : containers.joined(separator: "."))")
        } else if let macro = node.as(MacroExpansionDeclSyntax.self) {
            kind = .fragment(.macroExpansions, label: macroLabel("#" + macro.macroName.text))
        } else if let macro = node.as(MacroExpansionExprSyntax.self) {
            kind = .fragment(.macroExpansions, label: macroLabel("#" + macro.macroName.text))
        } else if let item = node.as(CodeBlockItemSyntax.self), !item.item.is(DeclSyntax.self) {
            if let macro = item.item.as(MacroExpansionExprSyntax.self) {
                kind = .fragment(.macroExpansions, label: macroLabel("#" + macro.macroName.text))
            } else {
                kind = .fragment(.topLevelCode, label: nil)
            }
        } else {
            return nil
        }
        return Region(
            id: node.id,
            kind: kind,
            line: line(at: node.positionAfterSkippingLeadingTrivia),
            endLine: line(at: node.endPositionBeforeTrailingTrivia),
            firstToken: node.firstToken(viewMode: .sourceAccurate)?.id,
            lastToken: node.lastToken(viewMode: .sourceAccurate)?.id
        )
    }

    func line(at position: AbsolutePosition) -> Int {
        converter.location(for: position).line
    }

    /// The line an end position sits on — the last line a piece of text occupies, not the one after it when the text ends on a newline.
    func endLine(from start: AbsolutePosition, length: Int) -> Int {
        line(at: start.advanced(by: max(length - 1, 0)))
    }

    func macroLabel(_ name: String) -> String {
        containers.isEmpty ? name : "\(name) in \(containers.joined(separator: "."))"
    }

    func close(_ closing: Region) {
        if case let .fragment(category, label) = closing.kind {
            append(category, OutsideDeclarations.Fragment(label: label, text: closing.text, line: closing.line, endLine: closing.endLine))
        }
        pendingTrailing = ""
    }

    func append(_ category: OutsideDeclarations.Category, _ fragment: OutsideDeclarations.Fragment) {
        result.fragments[category, default: []].append(fragment)
    }

    func handle(_ token: TokenSyntax) {
        if consumed.contains(token.id) {
            between(token.leadingTrivia, at: token.position)
            between(token.trailingTrivia, at: token.endPositionBeforeTrailingTrivia)
            return
        }
        guard var open = region else {
            between(token.leadingTrivia, at: token.position)
            // A type's braces are its header's and its members'; the end of the file is nothing at all. Any other
            // token outside every region is text no category claims, and is named as that rather than dropped.
            if token.parent?.is(MemberBlockSyntax.self) != true, token.tokenKind != .endOfFile {
                let start = token.positionAfterSkippingLeadingTrivia
                append(.other, OutsideDeclarations.Fragment(
                    label: nil,
                    text: token.text,
                    line: line(at: start),
                    endLine: line(at: token.endPositionBeforeTrailingTrivia)
                ))
            }
            between(token.trailingTrivia, at: token.endPositionBeforeTrailingTrivia)
            return
        }
        if case .containerHeader = open.kind {
            // The header's tokens are its signature, compared as the declaration's own line; what lies between them —
            // above all the doc comment, licence header or `// MARK:` in front of the type — is sorted like any other
            // text outside a declaration.
            between(token.leadingTrivia, at: token.position)
            between(token.trailingTrivia, at: token.endPositionBeforeTrailingTrivia)
            return
        }
        if token.id == open.firstToken {
            between(token.leadingTrivia, at: token.position)
        } else {
            open.text += pendingTrailing + Self.text(of: token.leadingTrivia)
        }
        open.text += token.text
        if token.id == open.lastToken {
            between(token.trailingTrivia, at: token.endPositionBeforeTrailingTrivia)
            pendingTrailing = ""
        } else {
            pendingTrailing = Self.text(of: token.trailingTrivia)
        }
        region = open
    }

    /// Trivia outside every region, piece by piece: a comment is a fragment of its own, whitespace is left to the line diff, anything else is ``OutsideDeclarations/Category/other``.
    func between(_ trivia: Trivia, at start: AbsolutePosition) {
        var position = start
        for piece in trivia {
            let length = piece.sourceLength.utf8Length
            if !piece.isWhitespace {
                var text = ""
                piece.write(to: &text)
                let fragment = OutsideDeclarations.Fragment(label: nil, text: text, line: line(at: position), endLine: endLine(from: position, length: length))
                append(piece.isComment ? .comments : .other, fragment)
            }
            position = position.advanced(by: length)
        }
    }

    /// A `#if`/`#elseif`/`#else` line as one fragment; its tokens are then consumed rather than read as stray text.
    func recordCondition(_ clause: IfConfigClauseSyntax) {
        var text = clause.poundKeyword.text
        consumed.insert(clause.poundKeyword.id)
        if let condition = clause.condition {
            text += " " + condition.trimmedDescription
            for token in condition.tokens(viewMode: .sourceAccurate) {
                consumed.insert(token.id)
            }
        }
        let end = clause.condition?.endPositionBeforeTrailingTrivia ?? clause.poundKeyword.endPositionBeforeTrailingTrivia
        append(.conditions, OutsideDeclarations.Fragment(
            label: nil,
            text: text,
            line: line(at: clause.poundKeyword.positionAfterSkippingLeadingTrivia),
            endLine: line(at: end)
        ))
    }

    func recordEndif(_ block: IfConfigDeclSyntax) {
        consumed.insert(block.poundEndif.id)
        let line = line(at: block.poundEndif.positionAfterSkippingLeadingTrivia)
        // Recorded when the block opens rather than when `#endif` is reached, which puts it ahead of the clauses in
        // the list — harmless, since conditions are compared as a sequence of lines and `#endif` carries no text of
        // its own that could differ.
        append(.conditions, OutsideDeclarations.Fragment(label: nil, text: "#endif", line: line, endLine: line))
    }

    func recordOwnText(of node: Syntax, entries: [(name: String?, text: String)]) {
        let start = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        for entry in entries {
            result.ownText[OutsideDeclarations.SymbolKey(line: start.line, column: start.column, name: entry.name)] = entry.text
        }
    }

    func recordHeaderEnd(of container: Syntax?, at block: MemberBlockSyntax) {
        guard let container else { return }
        let start = converter.location(for: container.positionAfterSkippingLeadingTrivia)
        let key = OutsideDeclarations.SymbolKey(line: start.line, column: start.column, name: nil)
        result.headerEnds[key] = line(at: block.leftBrace.positionAfterSkippingLeadingTrivia)
    }

    /// One binding's own text for each name a `let a = 1, b = 2` records — the attributes, modifiers and keyword they share, then the binding alone — so an edit to `b` is not reported against `a` too.
    static func ownTexts(of variable: VariableDeclSyntax) -> [(name: String?, text: String)] {
        guard variable.bindings.count > 1 else { return [(nil, variable.trimmedDescription)] }
        let shared = [variable.attributes.trimmedDescription, variable.modifiers.trimmedDescription, variable.bindingSpecifier.text]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        var entries: [(name: String?, text: String)] = []
        for binding in variable.bindings {
            for name in identifiers(in: binding.pattern) {
                entries.append((name, shared + " " + binding.trimmedDescription.trimmingTrailingComma))
            }
        }
        return entries
    }

    /// The same for `case a, b`: each element on its own.
    static func ownTexts(of cases: EnumCaseDeclSyntax) -> [(name: String?, text: String)] {
        guard cases.elements.count > 1 else { return [(nil, cases.trimmedDescription)] }
        let shared = [cases.attributes.trimmedDescription, cases.modifiers.trimmedDescription, "case"]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return cases.elements.map { element in (SymbolNaming.enumCaseName(of: element), shared + " " + element.trimmedDescription.trimmingTrailingComma) }
    }

    static func identifiers(in pattern: PatternSyntax) -> [String] {
        if let identifier = pattern.as(IdentifierPatternSyntax.self) {
            return [SymbolNaming.name(of: identifier.identifier)]
        }
        if let tuple = pattern.as(TuplePatternSyntax.self) {
            return tuple.elements.flatMap { identifiers(in: $0.pattern) }
        }
        return []
    }

    static func text(of trivia: Trivia) -> String {
        var text = ""
        trivia.write(to: &text)
        return text
    }
}

private extension OutsideDeclarations.Visitor.Region {
    enum Kind {
        case declaration, containerHeader, fragment(OutsideDeclarations.Category, label: String?)
    }
}

private extension String {
    /// A list element's own text without the comma that separates it from the next one.
    var trimmingTrailingComma: String {
        hasSuffix(",") ? String(dropLast()) : self
    }
}
