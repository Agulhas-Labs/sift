//
// Copyright © Agulhas Labs
//

import SwiftSyntax

/// Names the shape of a slow expression, classified at the site from a fresh parse rather than through the index's stored facts.
struct BuildTimingExpressionShape {
    /// The shape of the outermost expression starting at `line`:`column` in `tree`, or `nil` when there is none there or it matches none of the three named shapes.
    static func name(atLine line: Int, column: Int, in tree: SourceFileSyntax, converter: SourceLocationConverter) -> String? {
        guard let expression = Self.expression(atLine: line, column: column, in: Syntax(tree), converter: converter) else {
            return nil
        }
        return Self.shape(of: expression)
    }
}

private extension BuildTimingExpressionShape {
    /// The outermost node under `node` whose start location is `line`:`column`, found by one top-down walk: a parent is checked before its children, so the first match is the outermost one.
    static func expression(atLine line: Int, column: Int, in node: Syntax, converter: SourceLocationConverter) -> ExprSyntax? {
        if let expression = node.as(ExprSyntax.self) {
            let location = expression.startLocation(converter: converter)
            if location.line == line, location.column == column {
                return expression
            }
        }
        for child in node.children(viewMode: .sourceAccurate) {
            if let found = Self.expression(atLine: line, column: column, in: child, converter: converter) {
                return found
            }
        }
        return nil
    }

    static func shape(of expression: ExprSyntax) -> String? {
        if isLongLiteralChain(expression) {
            return "long literal chain"
        }
        if isTernaryChain(expression) {
            return "ternary chain"
        }
        if isUntypedMixedCollectionLiteral(expression) {
            return "untyped mixed collection literal"
        }
        return nil
    }

    /// A chain of three or more `+` whose operands are all literals.
    static func isLongLiteralChain(_ expression: ExprSyntax) -> Bool {
        guard let leaves = plusChainLeaves(expression) else {
            return false
        }
        return leaves.count >= 4 && leaves.allSatisfy(Self.isLiteral)
    }

    /// The leaves of a chain of `+` operators rooted at `expression`, or `nil` when it is not one.
    static func plusChainLeaves(_ expression: ExprSyntax) -> [ExprSyntax]? {
        guard let infix = expression.as(InfixOperatorExprSyntax.self),
              let binaryOperator = infix.operator.as(BinaryOperatorExprSyntax.self),
              binaryOperator.operator.text == "+"
        else {
            return nil
        }
        let left = Self.plusChainLeaves(infix.leftOperand) ?? [infix.leftOperand]
        let right = Self.plusChainLeaves(infix.rightOperand) ?? [infix.rightOperand]
        return left + right
    }

    static func isLiteral(_ expression: ExprSyntax) -> Bool {
        expression.is(IntegerLiteralExprSyntax.self)
            || expression.is(FloatLiteralExprSyntax.self)
            || expression.is(StringLiteralExprSyntax.self)
            || expression.is(BooleanLiteralExprSyntax.self)
            || expression.is(NilLiteralExprSyntax.self)
    }

    /// A ternary whose else (or then) branch is itself a ternary.
    static func isTernaryChain(_ expression: ExprSyntax) -> Bool {
        guard let ternary = expression.as(TernaryExprSyntax.self) else {
            return false
        }
        return ternary.thenExpression.is(TernaryExprSyntax.self) || ternary.elseExpression.is(TernaryExprSyntax.self)
    }

    /// An array or dictionary literal with no type annotation on its binding whose elements are not all the same literal kind.
    static func isUntypedMixedCollectionLiteral(_ expression: ExprSyntax) -> Bool {
        guard let kinds = elementKinds(of: expression), !Self.hasTypeAnnotatedBinding(expression) else {
            return false
        }
        return Set(kinds).count > 1
    }

    /// The literal-kind name of every element of `expression`, when it is an array or dictionary literal; `nil` otherwise.
    static func elementKinds(of expression: ExprSyntax) -> [String]? {
        if let array = expression.as(ArrayExprSyntax.self) {
            return array.elements.map { Self.kind(of: $0.expression) }
        }
        if let dictionary = expression.as(DictionaryExprSyntax.self) {
            guard case let .elements(elements) = dictionary.content else {
                return []
            }
            return elements.map { Self.kind(of: $0.value) }
        }
        return nil
    }

    static func kind(of expression: ExprSyntax) -> String {
        // A `-` or `+` prefix on a numeric literal is a sign, not a different shape: `-1` is still an integer.
        if let prefix = expression.as(PrefixOperatorExprSyntax.self), ["-", "+"].contains(prefix.operator.text) {
            return kind(of: prefix.expression)
        }
        if expression.is(IntegerLiteralExprSyntax.self) {
            return "integer"
        }
        if expression.is(FloatLiteralExprSyntax.self) {
            return "float"
        }
        if expression.is(StringLiteralExprSyntax.self) {
            return "string"
        }
        if expression.is(BooleanLiteralExprSyntax.self) {
            return "boolean"
        }
        if expression.is(NilLiteralExprSyntax.self) {
            return "nil"
        }
        if expression.is(ArrayExprSyntax.self) {
            return "array"
        }
        if expression.is(DictionaryExprSyntax.self) {
            return "dictionary"
        }
        return "other"
    }

    /// Whether `expression` is the value of an initializer whose pattern binding names an explicit type.
    static func hasTypeAnnotatedBinding(_ expression: ExprSyntax) -> Bool {
        guard let initializer = expression.parent?.as(InitializerClauseSyntax.self),
              let binding = initializer.parent?.as(PatternBindingSyntax.self)
        else {
            return false
        }
        return binding.typeAnnotation != nil
    }
}
