//
// Copyright © Agulhas Labs
//

import SwiftParser
import SwiftSyntax

/// Reads one file's functions down to the shape of the first statement in each body, then lets the tree go.
///
/// A file is parsed once and every function in it is recorded in that pass, because asking per test would reparse the file once per test — three thousand parses on a three-thousand-test repository — and because the tree may not outlive the call that made it.
///
/// Only the openings that decide whether a test runs are emitted; a body that starts with ordinary code produces no record at all, which is what keeps the result compact on a repository where almost every test runs.
final class TestBodyScanner: SyntaxVisitor {
    private let converter: SourceLocationConverter
    private(set) var openings: [TestBodyOpening] = []

    init(converter: SourceLocationConverter) {
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    /// Parses `source` and returns its openings; the tree is local to this call and released when it returns.
    static func openings(in source: String, path: String) -> [TestBodyOpening] {
        let tree = Parser.parse(source: source)
        let scanner = TestBodyScanner(converter: SourceLocationConverter(fileName: path, tree: tree))
        scanner.walk(tree)
        return scanner.openings
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if let first = node.body?.statements.first, let disposition = Self.disposition(opening: first) {
            openings.append(TestBodyOpening(
                name: SymbolNaming.labeledName(base: SymbolNaming.name(of: node.name), parameters: node.signature.parameterClause.parameters),
                startLine: converter.location(for: node.positionAfterSkippingLeadingTrivia).line,
                endLine: converter.location(for: node.endPosition).line,
                disposition: disposition
            ))
        }
        // A function declared inside a body is not a test, exactly as the indexing visitor treats it.
        return .skipChildren
    }
}

private extension TestBodyScanner {
    /// What a body's first statement says about whether the test runs, or `nil` when it says nothing.
    static func disposition(opening item: CodeBlockItemSyntax) -> DeclaredTest.Disposition? {
        switch item.item {
        case let .stmt(statement):
            guard let thrown = statement.as(ThrowStmtSyntax.self),
                  let call = thrown.expression.as(FunctionCallExprSyntax.self),
                  calleeName(of: call) == "XCTSkip"
            else { return nil }
            return .skips(reason: firstStringArgument(of: call))
        case let .expr(expression):
            guard let call = unwrapping(expression).as(FunctionCallExprSyntax.self), let callee = calleeName(of: call) else { return nil }
            switch callee {
            case "XCTFail": return .excludedByXCTFail
            case "XCTSkipIf", "XCTSkipUnless": return .conditional(marker: callee)
            default: return nil
            }
        default:
            return nil
        }
    }

    /// The expression under any `try` and `await` wrapping it — `try XCTSkipIf(…)` is a call like any other once those are peeled off.
    static func unwrapping(_ expression: ExprSyntax) -> ExprSyntax {
        if let attempt = expression.as(TryExprSyntax.self) {
            return unwrapping(attempt.expression)
        }
        if let awaited = expression.as(AwaitExprSyntax.self) {
            return unwrapping(awaited.expression)
        }
        return expression
    }

    /// The bare name a call names, or `nil` when the callee is anything but an identifier.
    static func calleeName(of call: FunctionCallExprSyntax) -> String? {
        call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text
    }

    /// The content of the call's first string-literal argument, without its quotes.
    static func firstStringArgument(of call: FunctionCallExprSyntax) -> String? {
        for argument in call.arguments {
            if let literal = argument.expression.as(StringLiteralExprSyntax.self) {
                return literal.representedLiteralValue
            }
        }
        return nil
    }
}
