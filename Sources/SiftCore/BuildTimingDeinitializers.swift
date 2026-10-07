//
// Copyright © Agulhas Labs
//

import SwiftSyntax

/// Finds the `deinit` a timed line sits in, from a fresh parse, because the index records no declaration for one.
struct BuildTimingDeinitializers {
    /// The innermost `deinit` in `tree` that holds `line`, or `nil` when none does.
    static func range(containing line: Int, in tree: SourceFileSyntax, converter: SourceLocationConverter) -> Found? {
        let finder = Finder(line: line, converter: converter)
        finder.walk(tree)
        return finder.found
    }
}

extension BuildTimingDeinitializers {
    /// A `deinit` found: its first and last line, and the name of the class or actor it belongs to.
    struct Found {
        let lines: ClosedRange<Int>
        let owner: String?
    }
}

private extension BuildTimingDeinitializers {
    final class Finder: SyntaxVisitor {
        private let line: Int
        private let converter: SourceLocationConverter
        private(set) var found: Found?

        init(line: Int, converter: SourceLocationConverter) {
            self.line = line
            self.converter = converter
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
            let first = node.startLocation(converter: converter).line
            let last = node.endLocation(converter: converter).line
            if first <= line, line <= last {
                let owner = node.parent?.ancestorOrSelf(mapping: { ancestor -> String? in
                    ancestor.as(ClassDeclSyntax.self)?.name.text ?? ancestor.as(ActorDeclSyntax.self)?.name.text
                })
                found = Found(lines: first ... last, owner: owner)
            }
            return .skipChildren
        }
    }
}
