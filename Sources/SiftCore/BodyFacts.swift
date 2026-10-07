//
// Copyright © Agulhas Labs
//

import SwiftSyntax

/// What a declaration's subtree contains: the names it calls, the names it mentions, and the shapes it exhibits.
///
/// Computed lazily per declaration and thrown away with it. The scan is one pass and collects all three axes at once, because a query asking two body questions should not walk the subtree twice.
///
/// **Scope note that changes what answers mean:** the subtree of a *type* includes every member body, so `kind:class calls:fetch` matches a class one of whose methods calls `fetch`. That is the useful reading, but it means a body term on a container is a question about the container's whole contents, not about a body it has of its own.
struct BodyFacts {
    /// Base names of every call — `store.save(x)` contributes `save`, `Task { }` contributes `Task`.
    private(set) var calledNames: Set<String> = []
    /// Every identifier mentioned, including type references and property access — a superset of `calledNames`.
    private(set) var usedNames: Set<String> = []
    private(set) var shapes: Set<StructuralQuery.Shape> = []

    init(node: Syntax) {
        let scanner = Scanner(viewMode: .sourceAccurate)
        scanner.walk(node)
        calledNames = scanner.calledNames
        usedNames = scanner.usedNames
        shapes = scanner.shapes
    }
}

private extension BodyFacts {
    /// The single-pass collector behind `BodyFacts`.
    final class Scanner: SyntaxVisitor {
        var calledNames: Set<String> = []
        var usedNames: Set<String> = []
        var shapes: Set<StructuralQuery.Shape> = []

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            if let name = CalleeName.base(of: node.calledExpression) {
                calledNames.insert(name)
            }
            return .visitChildren
        }

        override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
            usedNames.insert(SymbolNaming.name(of: node.baseName))
            return .visitChildren
        }

        override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
            usedNames.insert(SymbolNaming.name(of: node.name))
            return .visitChildren
        }

        override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
            usedNames.insert(SymbolNaming.name(of: node.declName.baseName))
            return .visitChildren
        }

        override func visit(_: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
            shapes.insert(.closure)
            return .visitChildren
        }

        override func visit(_: AwaitExprSyntax) -> SyntaxVisitorContinueKind {
            shapes.insert(.await)
            return .visitChildren
        }

        override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind {
            shapes.insert(node.questionOrExclamationMark?.tokenKind == .exclamationMark ? .forceTry : .try)
            return .visitChildren
        }

        override func visit(_: ForceUnwrapExprSyntax) -> SyntaxVisitorContinueKind {
            shapes.insert(.forceUnwrap)
            return .visitChildren
        }

        override func visit(_ node: AsExprSyntax) -> SyntaxVisitorContinueKind {
            if node.questionOrExclamationMark?.tokenKind == .exclamationMark {
                shapes.insert(.forceCast)
            }
            return .visitChildren
        }

        /// The form `as!` actually takes in a parsed body.
        ///
        /// Operator folding is a *semantic* pass this tool never runs, so inside an unfolded `SequenceExpr` a cast is `UnresolvedAsExprSyntax`, not `AsExprSyntax`. Handling only the folded node would make `has:forceCast` silently return nothing — a false negative, which for a lint-shaped query reads as "the codebase is clean".
        override func visit(_ node: UnresolvedAsExprSyntax) -> SyntaxVisitorContinueKind {
            if node.questionOrExclamationMark?.tokenKind == .exclamationMark {
                shapes.insert(.forceCast)
            }
            return .visitChildren
        }

        override func visit(_: OptionalChainingExprSyntax) -> SyntaxVisitorContinueKind {
            shapes.insert(.optionalChain)
            return .visitChildren
        }
    }
}
