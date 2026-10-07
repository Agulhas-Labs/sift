//
// Copyright © Agulhas Labs
//

import SwiftSyntax

/// A function's or an initializer's parameter declared with a property wrapper's `@T`, which a call passing `$label:` gives a projected value through T's `init(projectedValue:)`.
struct WrappedParameter: Sendable, Equatable {
    /// The name a call of the declaration is spelled with: the function's base name, or the type's for an initializer.
    let callee: String
    /// Whether the declaration is an initializer, called through its type rather than by its own name.
    let isInitializer: Bool
    /// The parameter's argument label, which a projected argument writes with a leading `$`.
    let label: String
    /// The simple name of the wrapper the parameter is declared with.
    let wrapper: String
    /// The repo-relative path of the file declaring the parameter.
    let path: String
    /// The line of the parameter's `@T` attribute.
    let line: Int
    /// Every parameter of the declaration, which decides whether a call's labels can reach it.
    let parameters: ParameterLabels

    /// The `path:line` of the parameter's `@T` attribute.
    var declaredAt: String {
        "\(path):\(line)"
    }

    /// The parameter as one a `$label:` argument is passed to, where `type` is the type the declaration sits in, or `nil` where it has no argument label or belongs to no function or initializer.
    init?(_ parameter: FunctionParameterSyntax, wrapper: String, in type: String?, path: String, line: Int) {
        guard let label = WrittenArguments.label(parameter.firstName), let list = parameter.parent?.as(FunctionParameterListSyntax.self) else { return nil }
        let declaration = parameter.parent?.parent?.parent?.parent
        if let function = declaration?.as(FunctionDeclSyntax.self) {
            callee = function.name.identifier?.name ?? function.name.text
            isInitializer = false
        } else if declaration?.is(InitializerDeclSyntax.self) == true, let type {
            callee = type
            isInitializer = true
        } else {
            return nil
        }
        self.label = label
        self.wrapper = wrapper
        self.path = path
        self.line = line
        parameters = ParameterLabels(list)
    }

    /// Whether a call written with `arguments` passes `$label:` to this parameter and could be a call of its declaration, its labels read as the names they project.
    func receives(_ arguments: WrittenArguments) -> Bool {
        guard arguments.labels.contains("$" + label) else { return false }
        return parameters.accepts(WrittenArguments(
            labels: arguments.labels.map { $0.map { $0.hasPrefix("$") ? String($0.dropFirst()) : $0 } },
            hasTrailingClosure: arguments.hasTrailingClosure,
            trailingLabels: arguments.trailingLabels
        ))
    }
}
