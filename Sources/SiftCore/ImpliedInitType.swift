//
// Copyright © Agulhas Labs
//

import SwiftSyntax

/// The type a declaration states for an implied initializer call, with the path it is written under and the annotation node that states it, which is `nil` where `Self` stands for the enclosing type.
struct ImpliedInitType {
    let name: String
    let qualifier: String?
    let annotation: TypeSyntax?
}

extension ImpliedInitType {
    /// The type the binding `node` initializes is annotated with, or that the function, computed property or subscript returning `node` declares.
    static func declaredType(around node: Syntax) -> TypeSyntax? {
        if let binding = node.parent?.as(InitializerClauseSyntax.self)?.parent?.as(PatternBindingSyntax.self) {
            return binding.typeAnnotation?.type
        }
        let isReturned = node.parent?.is(ReturnStmtSyntax.self) == true
            || (node.parent?.is(CodeBlockItemSyntax.self) == true && node.parent?.parent?.as(CodeBlockItemListSyntax.self)?.count == 1)
        guard isReturned else { return nil }
        var ancestor = node.parent
        while let current = ancestor {
            if let function = current.as(FunctionDeclSyntax.self) {
                return mayBeBuilt(function.attributes) ? nil : function.signature.returnClause?.type
            }
            if let subscriptDecl = current.as(SubscriptDeclSyntax.self) {
                return mayBeBuilt(subscriptDecl.attributes) ? nil : subscriptDecl.returnClause.type
            }
            if let binding = current.as(PatternBindingSyntax.self) {
                let attributes = binding.parent?.parent?.as(VariableDeclSyntax.self)?.attributes
                return attributes.map(mayBeBuilt) == true ? nil : binding.typeAnnotation?.type
            }
            if let closure = current.as(ClosureExprSyntax.self) {
                return closure.statements.count == 1 ? returnType(of: closure) : nil
            }
            if let accessor = current.as(AccessorDeclSyntax.self) {
                if mayBeBuilt(accessor.attributes) {
                    return nil
                }
                ancestor = current.parent
                continue
            }
            if current.is(DeclSyntax.self) {
                return nil
            }
            ancestor = current.parent
        }
        return nil
    }

    /// Whether a declaration or accessor carries an attribute other than the compiler ones (`@MainActor`, `@available`, `@discardableResult`, `@inlinable`, `@objc`, `@Sendable`, `@escaping`, `@usableFromInline`, `@nonobjc`, `@preconcurrency`, `@inline(...)`), which could be a result builder deciding the type through `buildExpression`.
    private static func mayBeBuilt(_ attributes: AttributeListSyntax) -> Bool {
        let known: Set = [
            "MainActor", "available", "discardableResult", "inlinable", "objc", "Sendable",
            "escaping", "usableFromInline", "nonobjc", "preconcurrency", "inline",
        ]
        return attributes.contains { element in
            guard let attribute = element.as(AttributeSyntax.self) else { return false }
            return !known.contains(attribute.attributeName.trimmedDescription)
        }
    }

    /// Whether a closure is an argument of a call, subscript or macro expansion, in its list or trailing, so a result builder may bind it.
    private static func isCallArgument(_ closure: ClosureExprSyntax) -> Bool {
        guard let parent = closure.parent else { return false }
        return parent.is(LabeledExprSyntax.self) || parent.is(MultipleTrailingClosureElementSyntax.self)
            || parent.as(FunctionCallExprSyntax.self)?.trailingClosure == closure
            || parent.as(SubscriptCallExprSyntax.self)?.trailingClosure == closure
            || parent.as(MacroExpansionExprSyntax.self)?.trailingClosure == closure
            || parent.as(MacroExpansionDeclSyntax.self)?.trailingClosure == closure
    }

    /// The type a closure returns: the one its own signature writes, else the return type of the function type its binding is annotated with, or `nil` where neither is written.
    private static func returnType(of closure: ClosureExprSyntax) -> TypeSyntax? {
        if isCallArgument(closure) {
            return nil
        }
        if let written = closure.signature?.returnClause?.type {
            return written
        }
        guard var annotation = closure.parent?.as(InitializerClauseSyntax.self)?.parent?.as(PatternBindingSyntax.self)?.typeAnnotation?.type else { return nil }
        while true {
            if let attributed = annotation.as(AttributedTypeSyntax.self) {
                annotation = attributed.baseType
            } else if let optional = annotation.as(OptionalTypeSyntax.self) {
                annotation = optional.wrappedType
            } else if let tuple = annotation.as(TupleTypeSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first, only.firstName == nil {
                annotation = only.type
            } else {
                return annotation.as(FunctionTypeSyntax.self)?.returnClause.type
            }
        }
    }

    /// The declared type an implicit member is looked up in — an optional's wrapped type, or the type inside an unlabelled one-element tuple, `(T)`, which is only parentheses — taken `elementDepth` array elements in, or `nil` where it is no array that deep.
    static func unwrapped(_ type: TypeSyntax, elementDepth: Int) -> TypeSyntax? {
        if let optional = type.as(OptionalTypeSyntax.self) {
            return unwrapped(optional.wrappedType, elementDepth: elementDepth)
        }
        if let tuple = type.as(TupleTypeSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first, only.firstName == nil {
            return unwrapped(only.type, elementDepth: elementDepth)
        }
        if elementDepth > 0 {
            return type.as(ArrayTypeSyntax.self).flatMap { unwrapped($0.element, elementDepth: elementDepth - 1) }
        }
        return type
    }
}
