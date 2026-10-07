//
// Copyright © Agulhas Labs
//

import Foundation
import SwiftParser
import SwiftSyntax

/// The answer to `digest Type.init` for a struct that declares no initializer in its body, so the compiler writes its memberwise one.
///
/// The index holds no declaration for that initializer, so a lookup under the type found nothing and the path read as a member that does not exist. It is derived here from the stored properties instead, as the compiler does it: in declaration order, a `var` with an initial value taking a default and a `let` with one taking no parameter, with computed properties, static members and lazy properties left out. An initializer declared in an extension does not stop the compiler writing it, so only the struct's own body decides.
struct SynthesizedInitializer {
    let store: IndexStore
    /// A declaration's current source lines, which tell whether a property whose stored signature shows no initial value has one.
    let source: (SymbolRow) -> [String]?

    /// The structs `target` names, when it is a `Type.init`, that declare no initializer in their body; empty where it is not one or none does.
    func lookup(target: String) throws -> [Found] {
        let components = QualifiedPath.components(of: target)
        guard components.count > 1, components.last == "init" else { return [] }
        let qualifiers = Array(components.dropLast())
        let sameNamed = SameNamedTypes(store: store)
        var found: [Found] = []
        for row in try store.symbols(named: qualifiers.last ?? "") where row.kind == .structKind {
            guard try QualifiedPath.matches(qualifiers: Array(qualifiers.dropLast()), chain: store.parentChain(of: row).map(\.name), module: row.module),
                  let stored = try sameNamed.memberwiseProperties(of: row)
            else { continue }
            let properties = stored
            let labels = MemberwiseParameters(source: source).labels(of: properties)
            // A property that is no parameter, a `let` with a value, is the compiler's to leave out; the others are listed in the order written.
            var taken = labels.map { labels in properties.filter { property in labels.parameters.contains { $0.label == property.name } } } ?? properties
            // The initializer is as private as its least accessible parameter without a default, never above internal; a defaulted property below that is left out of it.
            let defaulted = Set(labels?.parameters.filter(\.isDefaulted).compactMap(\.label) ?? [])
            let required = taken.filter { !defaulted.contains($0.name) }
            let access = min(required.map(\.accessLevel).min() ?? .internalLevel, .internalLevel)
            let omitted = Set(taken.filter { defaulted.contains($0.name) && $0.accessLevel < access }.map(\.name))
            taken.removeAll { omitted.contains($0.name) }
            let range = (taken.map(\.line).min() ?? row.line, taken.map(\.endLine).max() ?? row.endLine)
            try found.append(Found(
                qualifiedName: store.qualifiedName(of: row) + ".init",
                path: row.path,
                line: range.0,
                endLine: range.1,
                parameters: labels.map { labels in labels.parameters.filter { !omitted.contains($0.label ?? "") }.compactMap { parameter in properties.first { $0.name == parameter.label }.map { Self.parameter($0, defaulted: parameter.isDefaulted) } } },
                access: access
            ))
        }
        return found
    }

    /// The lines `digest` serves for `found`: the header every member's answer opens with, then what the compiler writes and where its parameters come from.
    static func lines(for found: Found) -> [String] {
        let header = "\(found.qualifiedName) — initializer — \(found.path)\(found.rangeDescription)"
        let reason = "compiler-synthesized, not written in source: the type declares no init, so Swift writes its memberwise initializer from the stored properties at \(found.path)\(found.rangeDescription), in declaration order"
        let signature = found.parameters.map { "init(\($0.joined(separator: ", ")))" } ?? "its parameters could not be worked out from the stored properties' signatures; read them at \(found.path)\(found.rangeDescription)"
        let access = switch found.access {
        case .privateLevel: "access: private, because a stored property it takes is private"
        case .fileprivateLevel: "access: fileprivate, because a stored property it takes is fileprivate"
        default: "access: internal"
        }
        return [header, "", reason, signature, access]
    }

    /// `name: Type` for a stored property, followed by ` = …` where the parameter has a default; the initial value itself is shown where the stored signature carries it.
    private static func parameter(_ property: SymbolRow, defaulted: Bool) -> String {
        let tree = Parser.parse(source: property.signature)
        var label = property.name + ": <inferred>"
        var initial: String?
        if let declaration = tree.statements.first?.item.as(VariableDeclSyntax.self) {
            let bindings = Array(declaration.bindings)
            if let index = bindings.firstIndex(where: { $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == property.name }) {
                if let type = bindings[index...].lazy.compactMap(\.typeAnnotation).first?.type {
                    label = property.name + ": " + type.trimmedDescription
                }
                initial = bindings[index].initializer?.value.trimmedDescription
                // An optional `var` with no value is defaulted to nil, which is no guess.
                if initial == nil, let type = bindings[index...].lazy.compactMap(\.typeAnnotation).first?.type, type.is(OptionalTypeSyntax.self) {
                    initial = "nil"
                }
            }
        }
        return defaulted ? label + " = " + (initial ?? "…") : label
    }
}

extension SynthesizedInitializer {
    /// One struct a `Type.init` path names whose memberwise initializer is the compiler's.
    struct Found {
        let qualifiedName: String
        let path: String
        let line: Int
        let endLine: Int
        /// The memberwise parameters as written in a call, or `nil` where a stored signature does not say which properties are parameters.
        let parameters: [String]?
        let access: AccessLevel

        var rangeDescription: String {
            line == endLine ? ":\(line)" : ":\(line)-\(endLine)"
        }
    }
}

extension DigestRenderer {
    /// The current source of a qualified member target, with the memberwise initializer the compiler writes said beside it where the target is a `Type.init` of a struct that declares none in its body.
    ///
    /// An initializer declared in an extension leaves the compiler's memberwise one in place, so it is answered beside the declared one rather than instead of it.
    func renderMemberBody(target: String, options: DigestOptions) throws -> String? {
        let declared = try renderDeclaredMemberBody(target: target, options: options)
        let found = try SynthesizedInitializer(store: store) { [repoRoot] row in
            guard case let .lines(lines, _) = SourceSlicer.slice(of: row, under: repoRoot) else { return nil }
            return lines
        }.lookup(target: target)
        guard !found.isEmpty else { return declared }
        let paths = found.map(\.path)
        let preamble = try parseErrorBanner(touching: paths) + guessedModuleBanner(touching: paths)
        let blocks = found.map { SynthesizedInitializer.lines(for: $0).joined(separator: "\n") }
        let synthesized = (preamble + [blocks.joined(separator: "\n\n")]).joined(separator: "\n")
        return declared.map { $0 + "\n\n" + synthesized } ?? synthesized
    }
}
