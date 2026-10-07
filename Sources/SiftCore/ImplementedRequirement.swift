//
// Copyright © Agulhas Labs
//

import Foundation
import IndexStoreDB

/// A declaration the index store records a function, property or subscript as implementing: a protocol requirement it satisfies, or a superclass member it overrides.
///
/// A call or a read made through the protocol or the superclass is recorded against that declaration, or (made inside a library, as `sorted()` calls `<` and string interpolation reads `description`) not recorded at all, and never against the implementation itself. So its own callers, reads and writes are only its direct ones, and an empty list of them is no evidence it is unused: the answer says so in the line that would otherwise say "no callers" or "no reads or writes", and names only what the store holds.
struct ImplementedRequirement: Equatable {
    /// The requirement or overridden member, as the store names it: `<(_:_:)`.
    let name: String
    /// The protocol or class that declares it, `nil` where the store holds no symbol that tells.
    let owner: Owner?
    /// Whether the declaration is itself a protocol's requirement, which declares this one again rather than satisfying it.
    let restated: Bool

    /// The hedge said in place of a bare "no callers" or "no reads or writes", or beside a count of them, for a declaration that implements `requirements`: what it implements, and that a call or use made through that is not recorded against it.
    ///
    /// Worded from what was checked — that nothing is recorded against the declaration itself — and never pointing at the requirement as where its callers are: a call a library makes through it is recorded nowhere in the store.
    static func hedge(_ requirements: [ImplementedRequirement], relation: Relation = .calls) -> String {
        let named = requirements.map { requirement in
            guard let owner = requirement.owner else { return "\(requirement.restated ? "restates" : "implements") \(requirement.name)" }
            let verb = requirement.restated ? "restates" : owner.isProtocol ? "satisfies" : "overrides"
            return "\(verb) \(owner.name).\(requirement.name)"
        }
        let owners = requirements.compactMap(\.owner)
        let act = "a \(relation.act) made through"
        let through = if owners.count == requirements.count, owners.allSatisfy(\.isProtocol) {
            "\(act) \(owners.map(\.name).joined(separator: " or ")), including one a library makes,"
        } else if owners.count == requirements.count, !owners.contains(where: \.isProtocol) {
            "\(act) \(owners.map(\.name).joined(separator: " or ")), as a superclass reference or a library makes one,"
        } else {
            "\(act) what it implements"
        }
        return "it \(named.joined(separator: " and ")), so \(through) is not recorded against it"
    }

    /// The heading of a declaration's listed callers, or of a property's or subscript's listed reads and writes, and the qualifier its count carries: `direct callers of X (N, it satisfies …)` or `direct reads and writes of X (N, …)` for one that implements `requirements`, since nothing made through them is among those listed.
    static func listHeading(of qualified: String, implementing requirements: [ImplementedRequirement], relation: Relation = .calls) -> (title: String, qualifier: String?) {
        guard !requirements.isEmpty else { return ("\(relation.listed) of \(qualified)", nil) }
        return ("direct \(relation.listed) of \(qualified)", hedge(requirements, relation: relation))
    }

    /// Files a declaration with nothing recorded against it in `relation`: by name among the plain empties a summary line counts when it implements nothing, else as a hedged line of its own, out of that summary's arithmetic, carrying the note `verdict`'s lines carry of the test files the store does not hold.
    static func file(_ qualified: String, implementing requirements: [ImplementedRequirement], relation: Relation, verdict: ZeroUseVerdict, plain: inout [String], hedged: inout [String]) {
        if requirements.isEmpty {
            plain.append(qualified)
        } else {
            hedged.append("no direct \(relation.empty) of \(qualified) recorded in the store\(verdict.hedge) — " + hedge(requirements, relation: relation))
        }
    }
}

extension ImplementedRequirement {
    /// What an implementation was asked for: a function's callers, or a property's or subscript's reads and writes.
    enum Relation {
        case calls
        case uses

        /// The relation as an empty case names it: `no direct callers`, `no direct reads or writes`.
        var empty: String {
            self == .calls ? "callers" : "reads or writes"
        }

        /// The relation as its listing is headed: `callers`, `reads and writes`.
        var listed: String {
            self == .calls ? "callers" : "reads and writes"
        }

        /// One instance of it, as the hedge names one made through the requirement.
        var act: String {
            self == .calls ? "call" : "use"
        }
    }

    /// The protocol or class a requirement belongs to, by the kind the store records for it.
    struct Owner: Equatable {
        let name: String
        let isProtocol: Bool

        /// The owner a symbol of `kind` can be, `nil` for any kind but a protocol or a class: nothing else declares a member another implements.
        init?(_ name: String, kind: IndexSymbolKind) {
            guard kind == .protocol || kind == .class, !name.isEmpty else { return nil }
            self.name = name
            isProtocol = kind == .protocol
        }
    }
}
