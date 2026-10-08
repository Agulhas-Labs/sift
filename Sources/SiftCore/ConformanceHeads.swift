//
// Copyright © Agulhas Labs
//

import Foundation
import SwiftParser
import SwiftSyntax

/// The names an inheritance clause or a typealias writes as what is conformed to, read from a parse of the source rather than from its text, each with where its token starts.
///
/// A name written anywhere else in a declaration — a member's type, a generic argument, a where clause, a nested type's own clause — is not one of them, and a head is matched to the store's reference by line and column, never by its spelling, so a mention, or another type of the same name, is never taken for a conformance.
struct ConformanceHeads {
    /// The heads each type, protocol or extension declaration in `source` writes in its own inheritance clause, and each typealias in its underlying type (never its where clause), keyed by where the declaration starts, its attributes included, which is where the index puts its row.
    static func declarations(in source: String) -> [Start: [String: Set<Start>]] {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: "", tree: tree)
        var found: [Start: [String: Set<Start>]] = [:]
        var pending = [Syntax(tree)]
        while let node = pending.popLast() {
            pending += node.children(viewMode: .sourceAccurate)
            let types: [TypeSyntax] = if let group = node.asProtocol(DeclGroupSyntax.self) {
                group.inheritanceClause?.inheritedTypes.map(\.type) ?? []
            } else if let alias = node.as(TypeAliasDeclSyntax.self) {
                [alias.initializer.value]
            } else {
                []
            }
            guard !types.isEmpty else { continue }
            var heads: [String: Set<Start>] = [:]
            for token in types.flatMap(Self.heads(of:)) {
                let location = converter.location(for: token.positionAfterSkippingLeadingTrivia)
                heads[Self.name(of: token), default: []].insert(Start(line: location.line, column: location.column))
            }
            let start = converter.location(for: node.positionAfterSkippingLeadingTrivia)
            found[Start(line: start.line, column: start.column)] = heads
        }
        return found
    }

    /// The name tokens `type` writes as what is conformed to: an identifier's or a member type's own last name, each element of a composition, under any attribute; never a generic argument, an existential's protocol or a suppressed `~Copyable`.
    static func heads(of type: TypeSyntax) -> [TokenSyntax] {
        if let identifier = type.as(IdentifierTypeSyntax.self) {
            return [identifier.name]
        }
        if let member = type.as(MemberTypeSyntax.self) {
            return [member.name]
        }
        if let composition = type.as(CompositionTypeSyntax.self) {
            return composition.elements.flatMap { Self.heads(of: $0.type) }
        }
        if let attributed = type.as(AttributedTypeSyntax.self) {
            return Self.heads(of: attributed.baseType)
        }
        return []
    }

    /// A name token's text with any backticks taken off.
    private static func name(of token: TokenSyntax) -> String {
        token.text.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
    }
}

extension ConformanceHeads {
    /// Where a declaration or token starts, as the index records it: the 1-based line and UTF-8 column.
    struct Start: Hashable {
        let line: Int
        let column: Int
    }

    /// The heads of the files a conformers block reads, each file parsed once and only its heads kept.
    struct Files {
        let root: URL
        private var parsed: [String: [Start: [String: Set<Start>]]] = [:]

        init(root: URL) {
            self.root = root
        }

        /// Whether `row`'s own inheritance clause, or its underlying type where it is a typealias, writes `name` with its token starting at `line`:`column` in the working tree's copy of the row's file.
        mutating func declaration(_ row: SymbolRow, writes name: String, atLine line: Int, column: Int) -> Bool {
            (heads(of: row)[name] ?? []).contains(Start(line: line, column: column))
        }

        /// Whether `row`'s own inheritance clause, or its underlying type where it is a typealias, writes any name with its token starting at `line`:`column` in the working tree's copy of the row's file.
        mutating func declaration(_ row: SymbolRow, writesAHeadAtLine line: Int, column: Int) -> Bool {
            heads(of: row).values.contains { $0.contains(Start(line: line, column: column)) }
        }

        /// The names `row`'s own inheritance clause, or its underlying type where it is a typealias, writes in the working tree's copy of the row's file, wherever each stands in the clause.
        mutating func names(writtenBy row: SymbolRow) -> Set<String> {
            Set(heads(of: row).keys)
        }

        /// The heads `row`'s own clause writes, by name, its file parsed on first use.
        private mutating func heads(of row: SymbolRow) -> [String: Set<Start>] {
            if parsed[row.path] == nil {
                let source = try? String(contentsOf: root.appendingPathComponent(row.path), encoding: .utf8)
                parsed[row.path] = source.map(ConformanceHeads.declarations(in:)) ?? [:]
            }
            return parsed[row.path]?[Start(line: row.line, column: row.column)] ?? [:]
        }
    }
}
