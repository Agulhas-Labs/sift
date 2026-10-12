//
// Copyright © Agulhas Labs
//

import Foundation

/// The notes a module and a type of one name each leave on the other's digest: wraps `DigestRenderer` rather than extending it, to keep `DigestRenderer.swift` under the line-length guideline.
///
/// A module and a type can share a name — every SwiftPM executable target with an eponymous entry-point type does. A bare name serves the type; the module is reached by `Name/`, and each answer says so.
struct DigestModuleShadow {
    let renderer: DigestRenderer
    let name: String

    /// The types a bare `name` would serve in place of the module.
    func types() throws -> [SymbolRow] {
        try renderer.store.typeDeclarations(named: name)
    }

    /// The closing lines of a type answer for a bare name that is also a module.
    func moduleNote(options: DigestOptions) -> [String] {
        guard options.servesModules else {
            return ["", "a module named \(name) also exists — `digest --at` does not serve modules"]
        }
        return ["", "a module named \(name) also exists — `digest \(name)/` serves it"]
    }

    /// The closing lines of a module answer, naming the type a bare name serves: the qualified target of each, since `where` promises candidates over silent guessing; none where no type shares the name.
    func typeNote() throws -> [String] {
        let shared = try types()
        guard !shared.isEmpty else { return [] }
        let calls = try Set(shared.map { try renderer.qualifiedTarget(of: $0) })
            .sorted()
            .map { "`digest \($0)`" }
            .joined(separator: " or ")
        return ["", "a type named \(name) also exists — \(calls) serves it"]
    }
}
