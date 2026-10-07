//
// Copyright © Agulhas Labs
//

import SwiftParser
import SwiftSyntax

/// The types that share a simple name, and which of them a name-matched `T(…)` site builds.
///
/// A site is found by the type's simple name, so where two types share one — a top-level `Inner` and `Outer.Inner` — every `Inner(…)` in the tree is a site of both until something tells them apart, and listing it under both credits one type with the other's calls. Only the index store's word for the site leaves it out of a type's list (``StoreAttribution``): a qualifier written on it — for an implicit `.init call`, on the type its declaration states — is read through typealiases and supertypes and the typealiases declared inside them, but that reading is not sound, so a site it reads as another type's, or as no type's, is kept and noted (``QualifierReadings``). Its labels never leave it out, since a type may have initializers the scan cannot see — one an extension in another module or a protocol extension outside the index adds, literal coercion, a macro's, one inside `#if`; labels none of a type's known initializers take, where another's do, only credit the site to that other type and flag it under this one. Its scope, the innermost type around it that declares, inherits or aliases a type of the name (else the top level), likewise only says which of the types most likely builds it: a site kept for several is flagged under each its labels or scope do not name, and so is one qualified with a name the index cannot resolve, or inside a type whose superclass or protocol is outside the index, which may declare a type of the name itself.
struct SameNamedTypes {
    let store: IndexStore

    /// Every struct, class, enum and actor declaration named `name`, each with the types it is nested in and the initializers it has — none at all where `onlyShared` and fewer than two share the name.
    func candidates(named name: String, onlyShared: Bool = false) throws -> [Candidate] {
        let rows = try store.symbols(named: name).filter { Self.isConstructed($0.kind) }
        guard !onlyShared || rows.count > 1 else { return [] }
        let initializers = try store.symbols(named: "init").filter { $0.kind == .initializer }
        let chains = try initializers.map { try store.parentChain(of: $0) }
        let paths = chains.map { QualifiedPath.flattened(chain: $0.map(\.name)) }
        // An initializer a protocol extension declares is one every conforming type has, whoever it is.
        let lent = try zip(initializers, chains).filter { try isProtocolExtension($0.1.last) }.map { ParameterLabels(signature: $0.0.signature, name: $0.0.name) }
        return try rows.map { row in
            let parents = try QualifiedPath.flattened(chain: store.parentChain(of: row).map(\.name))
            let own = zip(initializers, paths).filter { $0.0.module == row.module && $0.1 == parents + [row.name] }
            return try Candidate(
                row: row,
                path: store.qualifiedName(of: row),
                parents: parents,
                initializers: own.map { ParameterLabels(signature: $0.0.signature, name: $0.0.name) },
                unwritten: lent.contains { $0 == nil } ? nil : unwritten(of: row, lent: lent.compactMap(\.self))
            )
        }
    }

    /// The flag a site kept for the types `asked` carries where it may build another type of the name, or `""` where nothing says it does.
    static func flag(of owners: Owners, for asked: Set<String>) -> String {
        if let fitted = owners.fitted, asked.isDisjoint(with: fitted) {
            return " (labels fit \(fitted.sorted().joined(separator: " or ")))"
        }
        let paths = (owners.fitted ?? owners.paths).sorted().joined(separator: " or ")
        let name = owners.paths.first.map { DeclaredTypeName.last(ofPath: $0) } ?? ""
        switch owners.outside {
        case let .qualifier(written, unresolved) where unresolved == [written]:
            return " (builds \(paths) only if \(written), which the index cannot resolve, names its scope)"
        case let .qualifier(written, unresolved):
            return " (builds \(paths) only if \(written), through \(unresolved.sorted().joined(separator: " or ")), which the index cannot resolve, names its scope)"
        case let .scopes(names):
            return " (unless unindexed \(names.sorted().joined(separator: " or ")) declares its own \(name))"
        case let .alias(target):
            return " (builds \(paths) — \(name) here is a typealias of \(target))"
        case nil:
            guard !owners.decided, owners.credited.map(asked.contains) != true else { return "" }
            return owners.credited.map { " (builds \(paths) — its scope names \($0))" } ?? " (builds \(paths) — nothing written tells which)"
        }
    }

    /// The counts of a type's name-matched sites left out of its list, by why: built as another type of the name, or a call of no type's init at all.
    static func dropped(another: Int, none: Int, named name: String) -> [String] {
        (another > 0 ? ["\(another) of another type named \(name) dropped"] : []) + (none > 0 ? ["\(none) calling no \(name).init dropped"] : [])
    }

    /// Whether a declaration of `kind` is a type built through an initializer.
    static func isConstructed(_ kind: SymbolKind) -> Bool {
        switch kind {
        case .structKind, .classKind, .enumKind, .actor: true
        default: false
        }
    }

    /// Whether `container` is an extension of a protocol the index declares.
    private func isProtocolExtension(_ container: SymbolRow?) throws -> Bool {
        guard let container, container.kind == .extensionKind else { return false }
        return try store.typeDeclarations(named: DeclaredTypeName.last(ofPath: container.name)).contains { $0.kind == .protocolKind }
    }

    /// The labels of the initializers `row` has that nobody declared under it — a struct's memberwise one where its body declares none, an enum's `init(rawValue:)` where it has a raw type, a decoding `init(from:)`, those `lent` by protocol extensions — or `nil` for a class or actor, which may inherit any.
    private func unwritten(of row: SymbolRow, lent: [ParameterLabels]) throws -> [ParameterLabels]? {
        let decoding = ParameterLabels(parameters: [ParameterLabels.Parameter(label: "from", isDefaulted: false, isVariadic: false)])
        switch row.kind {
        case .enumKind:
            let raw = ParameterLabels(parameters: [ParameterLabels.Parameter(label: "rawValue", isDefaulted: false, isVariadic: false)])
            return try lent + [decoding] + (store.inheritedNames(of: row.id).isEmpty ? [] : [raw])
        case .structKind:
            let members = try store.children(of: row.id)
            guard !members.contains(where: { $0.kind == .initializer }) else { return lent + [decoding] }
            return Self.memberwise(members.filter { $0.kind == .variable && $0.isStored && !$0.isStatic }).map { lent + [decoding, $0] }
        default:
            return nil
        }
    }

    /// The stored properties the memberwise initializer the compiler writes for the struct `row` is written from, in order, or `nil` where it writes none: `row` is no struct, or its body declares an initializer.
    func memberwiseProperties(of row: SymbolRow) throws -> [SymbolRow]? {
        guard row.kind == .structKind else { return nil }
        let members = try store.children(of: row.id)
        guard !members.contains(where: { $0.kind == .initializer }) else { return nil }
        return members.filter { $0.kind == .variable && $0.isStored && !$0.isStatic }
    }

    /// The labels of the memberwise initializer the compiler writes for stored `properties`, or `nil` where a signature does not say whether its property is a parameter.
    ///
    /// Every parameter is taken as defaulted: a stored signature stops before a long initial value, so one showing none is no proof it has none, and leaving a label out is the generous reading.
    private static func memberwise(_ properties: [SymbolRow]) -> ParameterLabels? {
        var parameters: [ParameterLabels.Parameter] = []
        for property in properties {
            let tree = Parser.parse(source: property.signature)
            guard !tree.hasError, let declaration = tree.statements.first?.item.as(VariableDeclSyntax.self),
                  !declaration.modifiers.contains(where: { $0.name.tokenKind == .keyword(.lazy) }),
                  let binding = declaration.bindings.first(where: { $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == property.name }),
                  let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier
            else { return nil }
            if declaration.bindingSpecifier.tokenKind == .keyword(.let), binding.initializer != nil {
                continue
            }
            parameters.append(ParameterLabels.Parameter(label: WrittenArguments.label(identifier), isDefaulted: true, isVariadic: false))
        }
        return ParameterLabels(parameters: parameters)
    }
}

extension SameNamedTypes {
    /// One type a `T(…)` site may build.
    struct Candidate {
        let row: SymbolRow
        /// The module-qualified path, `App.Outer.Inner`.
        let path: String
        /// The names of the types it is nested in, outermost first.
        let parents: [String]
        /// The labels of each initializer declared under it, `nil` for one whose labels cannot be read.
        let initializers: [ParameterLabels?]
        /// The labels of the initializers it has that nobody declared under it, or `nil` where the scan cannot tell them all.
        let unwritten: [ParameterLabels]?

        /// Whether a call written with `arguments` reaches one of its initializers, or `nil` where it may reach one the scan cannot read.
        func fits(_ arguments: WrittenArguments) -> Bool? {
            if initializers.contains(where: { $0?.accepts(arguments) == true }) || unwritten?.contains(where: { $0.accepts(arguments) }) == true {
                return true
            }
            return unwritten == nil || initializers.contains { $0 == nil } ? nil : false
        }
    }

    /// The paths of the candidates a site may build, and whether what the site writes settled which.
    struct Owners {
        /// Every candidate nothing the site writes rules out.
        let paths: Set<String>
        let decided: Bool
        /// What the index cannot see that leaves the site untold, or `nil` where only the candidates themselves are in doubt.
        var outside: Outside?
        /// The one of `paths` the site's labels or scope names, where nothing settled it.
        var credited: String?
        /// Those of `paths` whose initializers take the site's labels, where the labels rule out another of them — which only credits and flags, since a type may have initializers the scan cannot see.
        var fitted: Set<String>?
        /// Whether the index store's recorded reference on the site's line settled it, which is sound, rather than what the site writes.
        var recorded = false
    }

    /// A scope the index cannot see into, which may be where the type a site builds is declared.
    enum Outside {
        /// A qualifier written on the call, and the names it stands for that the index declares no type, typealias or module for — a module outside it, a generic parameter, a typealias it never indexed, or an alias or supertype naming one of those.
        case qualifier(String, unresolved: Set<String>)
        /// The types around the site, or their superclasses and protocols, the index declares nothing for, which may declare a type or typealias of the name themselves.
        case scopes(Set<String>)
        /// What a typealias of the name around the site stands for, where it is not exactly one of the candidates.
        case alias(String)
    }

    /// What a site's written scope resolves to, read from the typealiases, supertypes and modules the index declares.
    struct Resolver {
        let store: IndexStore
        private let aliases: [String: Set<String>]
        private let typealiases: [SymbolRow]
        private let modules: Set<String>

        /// The standard library's commonest raw-value types, which an enum's inheritance clause names without inheriting anything from them — one left out is only flagged.
        private static let rawValueTypes: Set<String> = [
            "String", "Substring", "Character", "Bool", "Double", "Float", "Int", "Int8", "Int16", "Int32", "Int64", "UInt8",
        ]

        init(store: IndexStore) throws {
            self.store = store
            typealiases = try store.everyTypealias()
            aliases = MemberReceivers.aliasedNames(in: typealiases)
            modules = try Set(store.moduleNames())
        }

        /// The candidates `site` may build, where `candidates` are every constructed type of the name it is written with.
        ///
        /// A qualifier the index resolves fully settles it; nothing else rules a candidate out. Labels only credit the one candidate whose initializers take them where another's do not, else the site's scope credits one.
        func owners(of site: SyntacticCallSite, among candidates: [Candidate]) throws -> Owners {
            if let qualifier = site.qualifier {
                let written = try owners(qualifiedBy: qualifier, around: site, among: candidates)
                return written.outside == nil ? written : Self.fitted(written, among: candidates, by: site.arguments)
            }
            let all = Set(candidates.map(\.path))
            guard candidates.count > 1 else { return Owners(paths: all, decided: true) }
            let scope = try scope(of: site, among: candidates)
            var owners = Self.fitted(Owners(paths: all, decided: false, outside: scope.outside), among: candidates, by: site.arguments)
            if let fitted = owners.fitted, fitted.count == 1 {
                owners.credited = fitted.first
            } else if let credited = scope.credited, (owners.fitted ?? owners.paths).contains(credited) {
                owners.credited = credited
            }
            return owners
        }

        /// `owners` with the candidates whose initializers take `arguments` noted, where another candidate's known ones do not.
        private static func fitted(_ owners: Owners, among candidates: [Candidate], by arguments: WrittenArguments?) -> Owners {
            guard let arguments else { return owners }
            let pool = candidates.filter { owners.paths.contains($0.path) }
            let fits = pool.map { $0.fits(arguments) }
            guard fits.contains(true), fits.contains(false) else { return owners }
            var fitted = owners
            fitted.fitted = Set(zip(pool, fits).filter { $0.1 != false }.map(\.0.path))
            return fitted
        }

        /// The candidates a site written `qualifier.T(…)` builds: those declared under the scope it names, directly or through a typealias or supertype of it, or named by a typealias of T declared inside one of those — none where the index resolves that scope to types that have none, and any where it cannot resolve it.
        ///
        /// The qualifier's first name is looked up around the site first, as Swift's lookup goes: a generic parameter there is a scope the index cannot see, and a typealias a type around it declares is read as what it writes.
        private func owners(qualifiedBy written: String, around site: SyntacticCallSite, among candidates: [Candidate]) throws -> Owners {
            let head = written.split(separator: ".").first.map(String.init) ?? written
            guard !site.qualifiedByGenericParameter, let qualifier = try unshadowed(written, head: head, around: site) else {
                return Owners(paths: Set(candidates.map(\.path)), decided: false, outside: .qualifier(written, unresolved: [head]))
            }
            let named = candidates.filter { ("." + $0.path).hasSuffix("." + qualifier + "." + $0.row.name) }
            guard named.isEmpty else { return Owners(paths: Set(named.map(\.path)), decided: true) }
            let scope = DeclaredTypeName.last(ofPath: qualifier)
            let reach = try reach(of: scope)
            let reached = candidates.filter { $0.parents.last.map { $0 != scope && reach.names.contains($0) } == true }
            guard reached.isEmpty else { return Owners(paths: Set(reached.map(\.path)), decided: true) }
            if let aliased = try aliased(in: reach.names, among: candidates) {
                return aliased.credited.map { Owners(paths: [$0], decided: true) } ?? Owners(paths: Set(candidates.map(\.path)), decided: false, outside: aliased.outside)
            }
            guard !reach.unseen.isEmpty, !modules.contains(scope) else { return Owners(paths: [], decided: true) }
            return Owners(paths: Set(candidates.map(\.path)), decided: false, outside: .qualifier(qualifier, unresolved: reach.unseen))
        }

        /// `qualifier` with its first name, `head`, read as the typealias of that name the innermost type around `site` declaring one has, or a type it inherits from — `qualifier` itself where none does, `nil` where the innermost has a generic parameter of that name (seen from an extension of it too), or a typealias writing no single path, or shares its name with another type, whose typealias it may not be.
        private func unshadowed(_ qualifier: String, head: String, around site: SyntacticCallSite) throws -> String? {
            for enclosing in site.enclosingTypes.reversed() {
                let name = DeclaredTypeName.last(ofPath: enclosing)
                let declared = try store.typeDeclarations(named: name)
                if declared.contains(where: { Self.genericParameters(of: $0).contains(head) }) {
                    return nil
                }
                let scopes = try reach(of: name).names
                let targets = try typealiases.filter { $0.name == head }.filter { alias in
                    try store.parentChain(of: alias).last.map { scopes.contains(DeclaredTypeName.last(ofPath: $0.name)) } == true
                }.map(Self.target(of:))
                guard !targets.isEmpty else { continue }
                let written = Set(targets.compactMap(\.self))
                guard declared.count < 2 else { return nil }
                guard !targets.contains(nil), written.count == 1, let target = written.first else { return nil }
                return target + qualifier.dropFirst(head.count)
            }
            return qualifier
        }

        /// The candidate an unqualified site's scope names — declared, aliased or inherited by the innermost type around it that has one of the name, else the top-level one — and what around it the index cannot see into.
        private func scope(of site: SyntacticCallSite, among candidates: [Candidate]) throws -> (credited: String?, outside: Outside?) {
            var unseen: Set<String> = []
            for enclosing in site.enclosingTypes.reversed() {
                let reach = try reach(of: enclosing)
                if let found = try named(in: [enclosing], among: candidates) ?? named(in: reach.names.subtracting([enclosing]), among: candidates) {
                    return unseen.isEmpty ? found : (found.credited, .scopes(unseen))
                }
                unseen.formUnion(reach.unseen.subtracting(Self.rawValueTypes))
            }
            let top = candidates.filter(\.parents.isEmpty)
            return (top.count == 1 ? top[0].path : nil, unseen.isEmpty ? nil : .scopes(unseen))
        }

        /// What a scope among `scopes` has of the candidates' name: the candidate it declares, or the one a typealias it declares of the name stands for — `nil` where it has neither.
        private func named(in scopes: Set<String>, among candidates: [Candidate]) throws -> (credited: String?, outside: Outside?)? {
            let nested = candidates.filter { $0.parents.last.map(scopes.contains) == true }
            guard nested.isEmpty else { return (nested.count == 1 ? nested[0].path : nil, nil) }
            return try aliased(in: scopes, among: candidates)
        }

        /// The candidate a typealias of the candidates' name declared by a scope among `scopes` stands for, or what it stands for where that is not exactly one of them — `nil` where no such scope declares one.
        private func aliased(in scopes: Set<String>, among candidates: [Candidate]) throws -> (credited: String?, outside: Outside?)? {
            let name = candidates.first?.row.name
            let targets = try typealiases.filter { $0.name == name }.filter { alias in
                try store.parentChain(of: alias).last.map { scopes.contains(DeclaredTypeName.last(ofPath: $0.name)) } == true
            }.map(Self.target(of:))
            guard !targets.isEmpty else { return nil }
            let aliased = Set(candidates.filter { candidate in targets.contains { $0.map { ("." + candidate.path).hasSuffix("." + $0) } == true } }.map(\.path))
            let written = targets.map { $0 ?? "?" }.sorted().joined(separator: " or ")
            return aliased.count == 1 && !targets.contains(nil) ? (aliased.first, nil) : (nil, .alias(written))
        }

        /// The names of the generic parameters a type's declaration writes — `Log` for `struct Gen<Log: P>`.
        static func genericParameters(of type: SymbolRow) -> [String] {
            let tree = Parser.parse(source: type.signature + " {}")
            let clause = tree.statements.first.flatMap { Syntax($0.item).asProtocol(WithGenericParametersSyntax.self)?.genericParameterClause }
            return clause?.parameters.map(\.name.text) ?? []
        }

        /// The dotted path a typealias's right-hand side writes, generic arguments set aside, or `nil` where it writes anything else.
        static func target(of alias: SymbolRow) -> String? {
            guard let equals = alias.signature.firstIndex(of: "=") else { return nil }
            var parser = Parser(String(alias.signature[alias.signature.index(after: equals)...]))
            let type = TypeSyntax.parse(from: &parser)
            return type.hasError ? nil : DeclaredTypeName.path(of: type)
        }

        /// The names a scope written `name` stands for — itself, what a typealias of the name names, and every type those inherit from — and those among them the index declares no type or typealias for.
        private func reach(of name: String) throws -> (names: Set<String>, unseen: Set<String>) {
            let (supertypes, unseen) = try MemberReceivers(store: store).supertypes(of: [name], aliases: aliases)
            let declared = try aliases[name] != nil || !store.typeDeclarations(named: name).isEmpty
            return (supertypes.union([name]), declared ? unseen : unseen.union([name]))
        }
    }

    /// The candidates a site builds, taken first from the index store's own record where it covers the site's file as it stands.
    ///
    /// The store resolved every name the compiler saw, so where exactly one of the candidates is referenced on the site's line, that one is what the site builds, whatever its scope or labels suggest; anywhere else — no store, a file edited since the build, a line naming none or several of them — the site is told apart by what it writes (``SameNamedTypes/Resolver/owners(of:among:)``).
    struct StoreAttribution {
        let candidates: [Candidate]
        private let resolver: Resolver
        private let semantic: SemanticContext?
        private let freshness: OccurrenceFreshness?
        /// Each candidate's `path:line` places the store records a reference to it, by the candidate's path.
        private let recorded: [String: Set<String>]

        init(store: IndexStore, semantic: SemanticContext?, candidates: [Candidate]) throws {
            self.candidates = candidates
            resolver = try Resolver(store: store)
            self.semantic = semantic
            var recorded: [String: Set<String>] = [:]
            for candidate in candidates {
                guard let owned = semantic?.owner(of: candidate.row) else { continue }
                recorded[candidate.path] = Set(owned.context.store.references(ofUSR: owned.usr).map { "\(owned.context.relativePath($0.path)):\($0.line)" })
            }
            self.recorded = recorded
            freshness = semantic.map { OccurrenceFreshness(store: store, buildAnchor: $0.buildAnchor, relativePath: $0.relativePath) }
        }

        /// The candidates `site` builds.
        func owners(of site: SyntacticCallSite) throws -> Owners {
            if let semantic, let freshness, semantic.anyStoreHasUnit(forFile: site.path),
               case .live = freshness.state(of: semantic.repoRoot.appendingPathComponent(site.path).path)
            {
                let building = candidates.filter { recorded[$0.path]?.contains("\(site.path):\(site.line)") == true }
                if building.count == 1 {
                    return Owners(paths: [building[0].path], decided: true, recorded: true)
                }
            }
            return try resolver.owners(of: site, among: candidates)
        }
    }
}
