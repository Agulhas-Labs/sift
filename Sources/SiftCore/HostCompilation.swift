//
// Copyright © Agulhas Labs
//

import SwiftOperators
import SwiftParser
import SwiftSyntax

/// Which `#if` clauses of a file the host this runs on compiles, as far as the host can prove it.
///
/// A condition is decided only where the answer is a fact of the host: `os(…)`, `arch(…)`, `targetEnvironment(simulator)`, `canImport(…)` of a module the platform always or never has, the literals, and `!`, `&&` and `||` over those. Anything else — a custom flag such as `DEBUG`, a compiler or language version, a feature — is undecided, never false, so a test is called compiled out only where the platform rules it out.
struct HostCompilation {
    /// Every `#if` clause in `source`, nested ones included, each with the lines it spans and its state, the tree discarded once walked.
    static func regions(in source: String) -> [Region] {
        let tree = Parser.parse(source: source)
        let collector = RegionCollector(converter: SourceLocationConverter(fileName: "", tree: tree))
        collector.walk(tree)
        return collector.regions
    }

    /// What the host makes of `line`: compiled out where any clause around it is inactive, undecided where any is undecided, and active otherwise.
    static func state(atLine line: Int, in regions: [Region]) -> State {
        let around = regions.filter { $0.lines.contains(line) }.map(\.state)
        if around.contains(.inactive) {
            return .inactive
        }
        return around.contains(.undecided) ? .undecided : .active
    }

    /// The state of each clause of one `#if … #elseif … #else … #endif`, in order: a clause after one that is active is inactive, one after an undecided clause is at best undecided, and `#else` is the condition `true`.
    static func states(of clauses: [ExprSyntax?]) -> [State] {
        var earlier: State = .inactive
        return clauses.map { condition in
            let own = condition.map(evaluate) ?? .active
            let state: State = switch earlier {
            case .active: .inactive
            case .undecided: own == .inactive ? .inactive : .undecided
            case .inactive: own
            }
            earlier = or(earlier, own)
            return state
        }
    }

    /// One condition, folded so `&&` binds tighter than `||` as the compiler reads it.
    static func evaluate(_ condition: ExprSyntax) -> State {
        let folded = OperatorTable.standardOperators.foldAll(condition) { _ in }.as(ExprSyntax.self) ?? condition
        return value(of: folded)
    }
}

extension HostCompilation {
    /// What the host makes of one clause or one line.
    enum State: Equatable {
        case active
        case inactive
        case undecided
    }

    /// One clause's span of lines and what the host makes of it.
    struct Region: Equatable {
        let lines: ClosedRange<Int>
        let state: State
    }
}

private extension HostCompilation {
    final class RegionCollector: SyntaxVisitor {
        let converter: SourceLocationConverter
        var regions: [Region] = []

        init(converter: SourceLocationConverter) {
            self.converter = converter
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
            let states = HostCompilation.states(of: node.clauses.map(\.condition))
            for (clause, state) in zip(node.clauses, states) {
                let start = clause.startLocation(converter: converter).line
                let end = max(start, clause.endLocation(converter: converter).line)
                regions.append(Region(lines: start ... end, state: state))
            }
            return .visitChildren
        }
    }

    static func value(of expression: ExprSyntax) -> State {
        if let literal = expression.as(BooleanLiteralExprSyntax.self) {
            return literal.literal.tokenKind == .keyword(.true) ? .active : .inactive
        }
        if let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1, let inner = tuple.elements.first?.expression {
            return value(of: inner)
        }
        if let prefix = expression.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "!" {
            return not(value(of: prefix.expression))
        }
        if let infix = expression.as(InfixOperatorExprSyntax.self), let symbol = infix.operator.as(BinaryOperatorExprSyntax.self)?.operator.text {
            switch symbol {
            case "&&": return and(value(of: infix.leftOperand), value(of: infix.rightOperand))
            case "||": return or(value(of: infix.leftOperand), value(of: infix.rightOperand))
            default: return .undecided
            }
        }
        guard let call = expression.as(FunctionCallExprSyntax.self),
              let function = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text,
              call.arguments.count == 1,
              let argument = call.arguments.first?.expression.as(DeclReferenceExprSyntax.self)?.baseName.text
        else {
            return .undecided
        }
        return HostPlatform.decides(function, argument)
    }

    static func not(_ state: State) -> State {
        switch state {
        case .active: .inactive
        case .inactive: .active
        case .undecided: .undecided
        }
    }

    static func and(_ left: State, _ right: State) -> State {
        if left == .inactive || right == .inactive {
            return .inactive
        }
        return left == .active && right == .active ? .active : .undecided
    }

    static func or(_ left: State, _ right: State) -> State {
        if left == .active || right == .active {
            return .active
        }
        return left == .inactive && right == .inactive ? .inactive : .undecided
    }
}
