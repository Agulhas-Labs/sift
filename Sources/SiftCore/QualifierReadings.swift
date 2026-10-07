//
// Copyright © Agulhas Labs
//

/// Where a name-matched construction is written behind a qualifier the index reads as another type of the name's owner, or as an owner declaring no type of the name, which `where` notes beside the calls it keeps.
///
/// The reading is ``SameNamedTypes/Resolver``'s, and it is not sound: Swift also sees names the scan never writes down (an associated type a conformance infers, a macro's generated types, a supertype outside the index matched by its simple name), so a call it reads as another type's, or as no type's, is kept and counted, and only noted, as a type's qualified use is (``QualifiedTypeNameScope``).
struct QualifierReadings {
    /// What the kept calls are counted as, `this struct's`.
    private let asked: String
    private var another = OtherOwnerQualifiers.Lines()
    private var none = OtherOwnerQualifiers.Lines()

    /// Why the calls are counted all the same, said at the end of each clause.
    private static var because: String {
        "as a qualifier read from the index alone may name another type in Swift"
    }

    /// The readings of the calls of `types`, the asked declarations among the candidates.
    init(of types: [SameNamedTypes.Candidate]) {
        let kinds = Set(types.map(\.row.kind.rawValue))
        asked = "this \(kinds.count == 1 ? kinds.first ?? "type" : "type")'s"
    }

    /// Records `site`, noted where `owners`, the resolver's reading of it among `candidates`, names none of the types at `paths` — `nil` where nothing read it.
    mutating func add(_ site: SyntacticCallSite, owners: SameNamedTypes.Owners?, among candidates: [SameNamedTypes.Candidate], asked paths: Set<String>) {
        guard let owners else {
            another.add(site, owners: [])
            none.add(site, owners: [])
            return
        }
        another.add(site, owners: QualifiedTypeNameScope.otherOwners(owners, among: candidates, asked: paths))
        none.add(site, owners: Self.declaresNone(owners, site: site).map { [$0] } ?? [])
    }

    /// The clauses for the lines of `listed`, the calls the answer lists, written only behind such a qualifier.
    func clauses(named name: String, listed: [SyntacticCallSite]) -> [String] {
        let used = listed.reduce(into: [String: Set<Int>]()) { $0[$1.path, default: []].insert($1.line) }
        let read = another.clause(named: name, used: used, behind: "behind a qualifier the index reads as", asked: asked, because: Self.because)
        return [read, none.clauseDeclaringNone(named: name, used: used, because: Self.because)].compactMap(\.self)
    }

    /// The flag a kept call's row carries where `owners`, its reading among `candidates`, names none of the types at `paths`, or `""`.
    static func flag(of owners: SameNamedTypes.Owners, site: SyntacticCallSite, among candidates: [SameNamedTypes.Candidate], asked paths: Set<String>) -> String {
        let name = candidates.first?.row.name ?? ""
        if let qualifier = declaresNone(owners, site: site) {
            return " (behind a qualifier the index reads as \(qualifier), which declares no \(name))"
        }
        let others = QualifiedTypeNameScope.otherOwners(owners, among: candidates, asked: paths)
        guard !others.isEmpty else { return "" }
        return " (behind a qualifier the index reads as \(others.joined(separator: " or ")), \(others.count == 1 ? "which declares" : "each declaring") another \(name))"
    }

    /// The qualifier `site` writes, where `owners` settled on no type of the name behind it.
    private static func declaresNone(_ owners: SameNamedTypes.Owners, site: SyntacticCallSite) -> String? {
        guard owners.decided, owners.outside == nil, owners.paths.isEmpty, let qualifier = site.qualifier, !qualifier.isEmpty else { return nil }
        return qualifier
    }
}
