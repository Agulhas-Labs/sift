//
// Copyright © Agulhas Labs
//

import SwiftSyntax

/// The capitalised names a file binds as values — a variable or constant, a parameter of a function, closure or accessor, a capture, a function — any of which hides a type of the name where it is in scope, and none of which the index records once it is declared inside a body.
final class BoundValueNames: SyntaxVisitor {
    private(set) var names: Set<String> = []

    /// Every capitalised value name bound anywhere in `tree`, read file-wide rather than by scope, so a receiver it names is never mistaken for a type.
    static func of(_ tree: some SyntaxProtocol) -> Set<String> {
        let visitor = BoundValueNames(viewMode: .sourceAccurate)
        visitor.walk(tree)
        return visitor.names
    }

    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        insert(node.identifier)
    }

    override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
        insert(node.secondName ?? node.firstName)
    }

    override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
        insert(node.secondName ?? node.firstName)
    }

    override func visit(_ node: ClosureShorthandParameterSyntax) -> SyntaxVisitorContinueKind {
        insert(node.name)
    }

    override func visit(_ node: ClosureCaptureSyntax) -> SyntaxVisitorContinueKind {
        insert(node.name)
    }

    override func visit(_ node: AccessorParametersSyntax) -> SyntaxVisitorContinueKind {
        insert(node.name)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        insert(node.name)
    }

    private func insert(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
        let name = token.identifier?.name ?? token.text
        if name.first?.isUppercase == true {
            names.insert(name)
        }
        return .visitChildren
    }
}
