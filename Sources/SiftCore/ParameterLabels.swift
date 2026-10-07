//
// Copyright © Agulhas Labs
//

import SwiftParser
import SwiftSyntax

/// A function's or an initializer's parameters as far as they decide which written calls can reach it.
///
/// It answers one question, and answers it generously: could a call written with these labels be a call of this declaration? A "no" drops a site from a name-matched list, so every rule that lets Swift accept a call is honoured — a defaulted parameter left out, a variadic or a parameter pack taking any count, labels compared as the names they escape, an unlabeled trailing closure standing for any parameter — and nothing about types is judged.
struct ParameterLabels: Sendable, Equatable {
    let parameters: [Parameter]

    /// The parameters of a stored signature, or `nil` when it does not parse back to a function or initializer spelled `name`.
    ///
    /// A signature is the declaration's head as the index stored it, whitespace collapsed; one that no longer parses to its own labeled name — a comment that swallowed the rest of the line, a head the parser could not finish — cannot be trusted to say which calls it takes, so it narrows nothing.
    init?(signature: String, name: String) {
        let tree = Parser.parse(source: signature)
        guard !tree.hasError, let item = tree.statements.first?.item else { return nil }
        let list: FunctionParameterListSyntax
        let base: String
        if let function = item.as(FunctionDeclSyntax.self) {
            list = function.signature.parameterClause.parameters
            base = SymbolNaming.name(of: function.name)
        } else if let initializer = item.as(InitializerDeclSyntax.self) {
            list = initializer.signature.parameterClause.parameters
            base = "init"
        } else {
            return nil
        }
        guard SymbolNaming.labeledName(base: base, parameters: list) == name else { return nil }
        self.init(list)
    }

    /// The parameters a declaration's parameter clause writes.
    init(_ list: FunctionParameterListSyntax) {
        parameters = list.map { parameter in
            Parameter(
                label: WrittenArguments.label(parameter.firstName),
                isDefaulted: parameter.defaultValue != nil,
                // A parameter pack takes any number of values, none included, exactly as a variadic does.
                isVariadic: parameter.ellipsis != nil || parameter.type.is(PackExpansionTypeSyntax.self)
            )
        }
    }

    /// The labels as a compound name spells them — `(in:limit:)` — for a line that says which labels a list was narrowed by.
    var spelled: String {
        "(" + parameters.map { ($0.label ?? "_") + ":" }.joined() + ")"
    }

    /// Whether a call written with these arguments can be a call of this declaration.
    func accepts(_ arguments: WrittenArguments) -> Bool {
        if arguments.application == .mayBeUnapplied {
            return true
        }
        if let callee = arguments.calleeLabels {
            return callee == parameters.map(\.label)
        }
        if matches(parameter: 0, argument: 0, arguments) {
            return true
        }
        return arguments.alternateFirstLabels.contains { matches(parameter: 0, argument: 0, arguments.withFirstLabel($0)) }
    }

    /// Matches the parenthesised arguments from `argument` on against the parameters from `parameter` on, in order, trying every way a defaulted or variadic parameter can be skipped.
    private func matches(parameter: Int, argument: Int, _ arguments: WrittenArguments) -> Bool {
        guard argument < arguments.labels.count else {
            return matchesTrailing(from: parameter, arguments)
        }
        guard parameter < parameters.count else { return false }
        let current = parameters[parameter]
        if current.isSkippable, matches(parameter: parameter + 1, argument: argument, arguments) {
            return true
        }
        guard arguments.labels[argument] == current.label else { return false }
        guard current.isVariadic else {
            return matches(parameter: parameter + 1, argument: argument + 1, arguments)
        }
        // A variadic's first value carries its label and the rest are written bare, so it can end after any of them.
        var end = argument + 1
        while true {
            if matches(parameter: parameter + 1, argument: end, arguments) {
                return true
            }
            guard end < arguments.labels.count, arguments.labels[end] == nil else { return false }
            end += 1
        }
    }

    /// Matches the trailing closures against the parameters left from `parameter` on: the unlabeled one may stand for any of them past skippable ones, each labeled one for its own label.
    private func matchesTrailing(from parameter: Int, _ arguments: WrittenArguments) -> Bool {
        guard arguments.hasTrailingClosure else {
            return matchesLabeledTrailing(from: parameter, closure: 0, arguments)
        }
        var candidate = parameter
        while candidate < parameters.count {
            if matchesLabeledTrailing(from: candidate + 1, closure: 0, arguments) {
                return true
            }
            guard parameters[candidate].isSkippable else { return false }
            candidate += 1
        }
        return false
    }

    private func matchesLabeledTrailing(from parameter: Int, closure: Int, _ arguments: WrittenArguments) -> Bool {
        guard closure < arguments.trailingLabels.count else {
            return parameters[min(parameter, parameters.count)...].allSatisfy(\.isSkippable)
        }
        var candidate = parameter
        while candidate < parameters.count {
            if parameters[candidate].label == arguments.trailingLabels[closure],
               matchesLabeledTrailing(from: candidate + 1, closure: closure + 1, arguments)
            {
                return true
            }
            guard parameters[candidate].isSkippable else { return false }
            candidate += 1
        }
        return false
    }
}

extension ParameterLabels {
    /// The parameters of an initializer nobody wrote, as the compiler would declare it.
    init(parameters: [Parameter]) {
        self.parameters = parameters
    }

    /// One parameter, as much of it as a written call's labels are checked against.
    struct Parameter: Sendable, Equatable {
        /// The argument label a call writes, `nil` for `_`.
        let label: String?
        let isDefaulted: Bool
        let isVariadic: Bool

        /// Whether a call may pass nothing for it.
        var isSkippable: Bool {
            isDefaulted || isVariadic
        }
    }
}
