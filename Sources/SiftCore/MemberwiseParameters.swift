//
// Copyright © Agulhas Labs
//

import SwiftParser
import SwiftSyntax

/// The parameters of the memberwise initializer the compiler writes for a struct, each defaulted only where its property gives the compiler a value to default to.
///
/// A stored signature stops before an initial value over a few dozen characters, so `var weight: Int` may stand for `var weight: Int = …` and `let tag: String` for a constant that is no parameter at all: where the signature shows no initial value, the declaration's own source settles it, and where that cannot be read the parameter is read as defaulted, the generous reading.
struct MemberwiseParameters {
    /// The source lines of a declaration, read at query time, or `nil` where they cannot be read.
    let source: ((SymbolRow) -> [String]?)?

    /// The labels of the memberwise initializer written from the stored `properties`, in order, or `nil` where a property's signature does not say whether it is a parameter.
    func labels(of properties: [SymbolRow]) -> ParameterLabels? {
        var parameters: [ParameterLabels.Parameter] = []
        for property in properties {
            let tree = Parser.parse(source: property.signature)
            guard !tree.hasError, let declaration = tree.statements.first?.item.as(VariableDeclSyntax.self),
                  let shown = Self.binding(named: property.name, in: declaration),
                  let identifier = shown.binding.pattern.as(IdentifierPatternSyntax.self)?.identifier
            else { return nil }
            // Only a signature showing its initial value is known whole; otherwise one may have been cut from it.
            // A `lazy` property always has one, so it reads as a parameter with a default, as the compiler makes it.
            let written = shown.binding.initializer != nil ? shown : read(property)
            let parameter: Bool? = if let written {
                Self.isDefaulted(written)
            } else {
                true
            }
            guard let isDefaulted = parameter else { continue }
            parameters.append(ParameterLabels.Parameter(label: WrittenArguments.label(identifier), isDefaulted: isDefaulted, isVariadic: false))
        }
        return ParameterLabels(parameters: parameters)
    }

    /// Whether the property `written` binds is a defaulted parameter, or `nil` where it is no parameter: a `let` with an initial value.
    private static func isDefaulted(_ written: Written) -> Bool? {
        let isLet = written.declaration.bindingSpecifier.tokenKind == .keyword(.let)
        if written.binding.initializer != nil {
            return isLet ? nil : true
        }
        // An optional `var` defaults to nil, and a wrapped one to whatever its wrapper has, which the scan cannot see.
        let annotation = written.rest.lazy.compactMap(\.typeAnnotation).first?.type
        let isOptional = annotation.map { type in
            type.is(OptionalTypeSyntax.self) || type.is(ImplicitlyUnwrappedOptionalTypeSyntax.self) || type.as(IdentifierTypeSyntax.self)?.name.text == "Optional"
        } ?? false
        return !isLet && (isOptional || !written.declaration.attributes.isEmpty)
    }

    /// The declaration of `property` as its source writes it, or `nil` where the source cannot be read or holds no binding of its name.
    private func read(_ property: SymbolRow) -> Written? {
        guard let lines = source?(property) else { return nil }
        var pending = [Syntax(Parser.parse(source: lines.joined(separator: "\n")))]
        while let node = pending.popLast() {
            if let declaration = node.as(VariableDeclSyntax.self), let written = Self.binding(named: property.name, in: declaration) {
                return written
            }
            pending += node.children(viewMode: .sourceAccurate)
        }
        return nil
    }

    /// The binding of `declaration` that names `name` with a plain identifier.
    private static func binding(named name: String, in declaration: VariableDeclSyntax) -> Written? {
        let bindings = Array(declaration.bindings)
        guard let index = bindings.firstIndex(where: { $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == name }) else { return nil }
        return Written(declaration: declaration, binding: bindings[index], rest: Array(bindings[index...]))
    }
}

extension MemberwiseParameters {
    /// One binding of a declaration written whole, with the declaration and the bindings after it.
    private struct Written {
        let declaration: VariableDeclSyntax
        let binding: PatternBindingSyntax
        /// This binding and those after it, the first of which with a type annotation gives this one its type.
        let rest: [PatternBindingSyntax]
    }
}
