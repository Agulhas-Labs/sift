//
// Copyright © Agulhas Labs
//

/// Where a protocol's name is written behind a qualifier spelled as the owner of another type of the name, which `where` notes beside the sites and conformers it keeps.
///
/// Nothing is resolved and nothing is set apart. Which declaration a qualified name means is Swift's lookup to decide, through typealiases, supertypes, nested types of the same name and generic parameters, and every rule tried for reading a qualifier from the index alone has dropped real uses. So a qualifier is only compared by spelling: it spells an owner where it is the owner's path or a trailing part of it, the module included, and a site is noted only where its qualifier spells another type's owner and no asked declaration's. The note says the line may be that type's; the line stays listed and counted.
struct OtherOwnerQualifiers {
    /// The asked declarations' owners, each as a dotted path with the module first.
    private let asked: [String]
    /// The owners of the other type declarations of the name: the dotted path with the module first, and the path the note names it by, its module only where it is declared at the top level.
    private let others: [(path: String, label: String)]

    /// The scope for `name`, or `nil` where no asked row is of one of `kinds` or the index declares no other type of the name under another owner, so the answer is printed as before.
    init?(store: IndexStore, name: String, asked rows: [SymbolRow], kinds: Set<SymbolKind> = [.protocolKind]) throws {
        guard rows.contains(where: { kinds.contains($0.kind) }) else { return nil }
        let askedIDs = Set(rows.map(\.id))
        let askedPaths = try rows.map { try Self.ownerPath(of: $0, in: store).path }
        let others = try store.symbols(named: name)
            .filter { $0.kind.isTypeDeclaration && !askedIDs.contains($0.id) }
            .map { try Self.ownerPath(of: $0, in: store) }
            .filter { !askedPaths.contains($0.path) }
        guard !others.isEmpty else { return nil }
        asked = askedPaths
        self.others = others
    }

    /// The names of the other owners `qualifier` spells, empty where it spells none of them or also spells an asked declaration's owner.
    func owners(spelledBy qualifier: String?) -> [String] {
        guard let qualifier, !qualifier.isEmpty, !asked.contains(where: { Self.spells(qualifier, $0) }) else { return [] }
        return others.filter { Self.spells(qualifier, $0.path) }.map(\.label)
    }

    /// The mark a conformer's row ends with where every entry of its inheritance clause naming `name` writes it behind another owner's qualifier, or an empty string.
    func mark(clause inherited: [String], naming name: String) -> String {
        let naming = InheritedClause.components(of: inherited, naming: name)
        let spelled = naming.filter { written in
            let parts = written.split(separator: ".")
            return !owners(spelledBy: parts.dropLast().joined(separator: ".")).isEmpty
        }
        guard !naming.isEmpty, spelled.count == naming.count else { return "" }
        return "  (clause writes \(spelled.joined(separator: ", ")))"
    }

    /// Whether `qualifier` spells the owner at `path`: the whole path, or a trailing part of it.
    private static func spells(_ qualifier: String, _ path: String) -> Bool {
        ("." + path).hasSuffix("." + qualifier)
    }

    /// `row`'s owner as a dotted path with the module first, and as the note names it.
    private static func ownerPath(of row: SymbolRow, in store: IndexStore) throws -> (path: String, label: String) {
        let chain = try QualifiedPath.flattened(chain: store.parentChain(of: row).map(\.name))
        return (([row.module] + chain).joined(separator: "."), chain.isEmpty ? row.module : chain.joined(separator: "."))
    }
}

extension OtherOwnerQualifiers {
    /// Per line, whether every site of the name on it is written behind another owner's qualifier, and which owners those qualifiers spell.
    struct Lines {
        /// Per file and line, the other owners the qualifiers written there spell.
        private var spelled: [String: [Int: Set<String>]] = [:]
        private var unspelled: [String: Set<Int>] = [:]

        /// Records `site`, noted where `scope` finds its qualifier spelling another owner.
        mutating func add(_ site: SyntacticCallSite, scope: OtherOwnerQualifiers?) {
            add(site, owners: scope?.owners(spelledBy: site.qualifier) ?? [])
        }

        /// Records `site`, noted as possibly the type of the name under one of `owners` where there are any.
        mutating func add(_ site: SyntacticCallSite, owners: [String]) {
            if owners.isEmpty {
                unspelled[site.path, default: []].insert(site.line)
            } else {
                spelled[site.path, default: [:]][site.line, default: []].formUnion(owners)
            }
        }

        /// The verdict's clause for the lines of `used` that write `name` only behind another owner's qualifier, or `nil` where there are none.
        ///
        /// `behind` says how the qualifier relates to the owners named after it, `asked` names what the lines are kept as, and `because` why they are counted all the same.
        func clause(
            named name: String,
            used: [String: Set<Int>],
            behind: String = "only behind",
            asked: String = "this protocol's",
            because: String = "as a qualifier is compared here by spelling, not resolved"
        ) -> String? {
            let (count, owners) = noted(among: used)
            guard count > 0 else { return nil }
            let named = WhereRenderer.namedSpellings(owners.sorted())
            let declares = owners.count == 1 ? "which declares" : "each declaring"
            return "\(count) of them write\(count == 1 ? "s" : "") \"\(name)\" \(behind) \(named), \(declares) another \"\(name)\", "
                + "so may be that type's rather than \(asked) — counted all the same, \(because)"
        }

        /// The verdict's clause for the lines of `used` that call `name` only behind a qualifier the index reads as declaring no type of the name, each recorded with the qualifier as written, or `nil` where there are none.
        func clauseDeclaringNone(named name: String, used: [String: Set<Int>], because: String) -> String? {
            let (count, qualifiers) = noted(among: used)
            guard count > 0 else { return nil }
            let declares = qualifiers.count == 1 ? "which declares" : "each declaring"
            return "\(count) of them write\(count == 1 ? "s" : "") \"\(name)\" behind a qualifier the index reads as \(WhereRenderer.namedSpellings(qualifiers.sorted())), "
                + "\(declares) no \"\(name)\", so may call no \(name).init — counted all the same, \(because)"
        }

        /// How many of the lines of `used` have every site recorded on them noted, and the owners their notes name.
        private func noted(among used: [String: Set<Int>]) -> (count: Int, owners: Set<String>) {
            var count = 0
            var owners: Set<String> = []
            for (path, lines) in spelled {
                for (line, spelling) in lines where used[path]?.contains(line) == true && unspelled[path]?.contains(line) != true {
                    count += 1
                    owners.formUnion(spelling)
                }
            }
            return (count, owners)
        }
    }
}
