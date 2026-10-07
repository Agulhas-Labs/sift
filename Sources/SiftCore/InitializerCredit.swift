//
// Copyright © Agulhas Labs
//

/// Which of an initializer name's declarations each of its name-matched sites can call by its written arguments, so the name scan lists a site only for an initializer it reaches.
///
/// A site is matched against every declaration of the name, defaults allowed, as the scan read its arguments: a `@T` attribute on a property with an initial value passes `wrappedValue:` first, and a `$label:` argument `projectedValue:`. A site reaching only declarations the block does not stand for is another initializer's, listed apart under the ones it reaches; one reaching one it stands for and one it does not is listed with every one it reaches named, rather than credited to one; one reaching none keeps the flag label narrowing gives it.
struct InitializerCredit {
    private let declarations: [SymbolRow]
    private let asked: Set<Int64>
    private let name: (SymbolRow) -> String

    /// `nil` unless every declaration is an initializer whose labels can be read, where `asked` are the ones the block stands for and `name` spells a declaration as the answer does.
    init?(_ declarations: [SymbolRow], asked: [SymbolRow], named name: @escaping (SymbolRow) -> String) {
        guard !declarations.isEmpty, declarations.allSatisfy({ $0.kind == .initializer && ParameterLabels(signature: $0.signature, name: $0.name) != nil }) else { return nil }
        self.declarations = declarations
        self.asked = Set(asked.map(\.id))
        self.name = name
    }

    /// Whether `site`'s arguments reach at least one declaration and none of the ones the block stands for.
    func isAnotherInitializers(_ site: SyntacticCallSite) -> Bool {
        let reached = reached(by: site)
        return !reached.isEmpty && !reached.contains { asked.contains($0.id) }
    }

    /// The sites among `sites` whose arguments reach only other declarations, grouped by the declarations they reach as the answer spells them.
    func otherInitializersSites(among sites: [SyntacticCallSite]) -> [(reaching: String, sites: [SyntacticCallSite])] {
        let grouped = Dictionary(grouping: sites.filter(isAnotherInitializers)) { spelling(reached(by: $0)) }
        return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
    }

    /// The flag a listed site's row carries where its arguments reach more than one declaration and one the block does not stand for, so the heading alone would pick one for it.
    ///
    /// A block standing for several declarations lists its sites as theirs together, so a site reaching only those is left unflagged.
    func suffix(for site: SyntacticCallSite) -> String {
        let reached = reached(by: site)
        guard reached.count > 1, reached.contains(where: { !asked.contains($0.id) }) else { return "" }
        return " (labels reach \(spelling(reached)))"
    }

    /// The declarations `site`'s arguments reach, every one where it writes none.
    private func reached(by site: SyntacticCallSite) -> [SymbolRow] {
        declarations.filter { !SyntacticCallerFallback.LabelNarrowed.reaching([site], by: [$0]).isEmpty }
    }

    /// The declarations spelled as the answer names them, sorted and joined with "or".
    private func spelling(_ rows: [SymbolRow]) -> String {
        Set(rows.map(name)).sorted().joined(separator: " or ")
    }
}
