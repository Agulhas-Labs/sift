//
// Copyright © Agulhas Labs
//

import SwiftParser
import SwiftSyntax

/// The `#if` condition a declaration sits under, as `where` labels it: what tells two same-named declarations in different branches apart.
///
/// The index stores an `#else` clause as the bare `#else`, which says nothing on its own of which `#if` it is the other branch of; where the file as it stands still holds the clauses the index recorded around the declaration, the label names the clauses before it in the chain (`#else of #if os(macOS)`, `#elseif os(iOS) of #if os(macOS)`, `#else of #if os(macOS), #elseif os(iOS)`), and otherwise it is the stored text.
struct IfConfigLabel {
    /// The label for `row`, or `nil` where it sits under no `#if`; `source` reads a repo-relative file as it stands, and is asked only for a row under an `#else`.
    static func label(for row: SymbolRow, source: ((String) -> String?)?) -> String? {
        guard let stored = row.ifConfigCondition else { return nil }
        guard stored.contains("#else"), let text = source?(row.path) else { return stored }
        let clauses = clauses(around: row.line, in: text)
        // The clauses read now must be the ones the index recorded, or the file has moved since and the stored text is all that is known.
        guard clauses.map(\.recorded).joined(separator: " && ") == stored else { return stored }
        return clauses.map(\.labelled).joined(separator: " && ")
    }

    /// The label for line `line` of `text`, read from the text alone, or `nil` where the line sits under no `#if`: for a declaration the index holds no condition for, such as a deinit read out of its type's lines.
    static func label(line: Int, in text: String) -> String? {
        let clauses = clauses(around: line, in: text)
        return clauses.isEmpty ? nil : clauses.map(\.labelled).joined(separator: " && ")
    }

    /// Every clause of `text` whose lines hold `line`, outermost first, the tree discarded once walked.
    private static func clauses(around line: Int, in text: String) -> [Clause] {
        let tree = Parser.parse(source: text)
        let collector = ClauseCollector(line: line, converter: SourceLocationConverter(fileName: "", tree: tree))
        collector.walk(tree)
        return collector.clauses
    }
}

private extension IfConfigLabel {
    /// One clause around the declaration's line: as the index records it, and as the label names it.
    struct Clause {
        let recorded: String
        let labelled: String
    }

    /// Every clause whose lines hold `line`, outermost first, the tree discarded once walked.
    final class ClauseCollector: SyntaxVisitor {
        let line: Int
        let converter: SourceLocationConverter
        var clauses: [Clause] = []

        init(line: Int, converter: SourceLocationConverter) {
            self.line = line
            self.converter = converter
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
            // Every clause before this one in the chain, so an `#elseif` or `#else` names the whole chain it closes, not only its `#if`.
            var earlier: [String] = []
            for clause in node.clauses {
                let recorded = clause.condition.map { clause.poundKeyword.text + " " + $0.trimmedDescription } ?? "#else"
                defer { earlier.append(recorded) }
                let start = clause.poundKeyword.startLocation(converter: converter).line
                let end = max(start, clause.endLocation(converter: converter).line)
                guard (start ... end).contains(line) else { continue }
                let labelled = earlier.isEmpty ? recorded : recorded + " of " + earlier.joined(separator: ", ")
                clauses.append(Clause(recorded: recorded, labelled: labelled))
            }
            return .visitChildren
        }
    }
}
