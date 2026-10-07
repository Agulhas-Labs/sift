//
// Copyright © Agulhas Labs
//

import SwiftParser
import SwiftSyntax

/// Finds where a file's function bodies are, from a fresh parse, so an expression's time can be told from time a body already holds.
struct BuildTimingBodySpans {
    /// The outermost body of every function, initializer, `deinit`, accessor and getter in `source`.
    static func spans(in source: String) -> [Span] {
        let tree = Parser.parse(source: source)
        let finder = Finder(converter: SourceLocationConverter(fileName: "", tree: tree))
        finder.walk(tree)
        return finder.spans
    }
}

extension BuildTimingBodySpans {
    /// One body's first and last position, as the compiler prints them: a line and a one-based column.
    struct Span {
        let start: (line: Int, column: Int)
        let end: (line: Int, column: Int)

        /// Whether `line`:`column` lies inside this body.
        func holds(line: Int, column: Int) -> Bool {
            (line, column) >= start && (line, column) <= end
        }
    }
}

private extension BuildTimingBodySpans {
    final class Finder: SyntaxVisitor {
        private let converter: SourceLocationConverter
        private(set) var spans: [Span] = []

        init(converter: SourceLocationConverter) {
            self.converter = converter
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
            record(node.body)
        }

        override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
            record(node.body)
        }

        override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
            record(node.body)
        }

        override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind {
            record(node.body)
        }

        override func visit(_ node: AccessorBlockSyntax) -> SyntaxVisitorContinueKind {
            guard case let .getter(items) = node.accessors else {
                return .visitChildren
            }
            return record(items)
        }

        /// Notes `node`'s span and skips what is inside it, whose time its outer body holds; a declaration with no body is walked on.
        private func record(_ node: (some SyntaxProtocol)?) -> SyntaxVisitorContinueKind {
            guard let node else {
                return .visitChildren
            }
            let start = node.startLocation(converter: converter)
            let end = node.endLocation(converter: converter)
            spans.append(Span(start: (start.line, start.column), end: (end.line, end.column)))
            return .skipChildren
        }
    }
}
