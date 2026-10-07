//
// Copyright © Agulhas Labs
//

import Foundation

/// The answer to `T.init` where T declares no initializer of its own, so the path resolves to nothing although T is built.
///
/// Such a type is built with an initializer nobody wrote — the compiler's memberwise one, `init(rawValue:)`, a default `init()` — or one it inherits from its superclass, so the index holds no declaration under T for the path to find. Answered as a path that does not resolve, it listed every other type's `init` and not one place T is built, which sent the reader looking for a member that was never written. What the question is after is where T is constructed, and T's name finds that.
struct UndeclaredInitializer {
    let store: IndexStore
    /// The open index store, whose recorded references to each type say which of two same-named types a site in a file it covers builds.
    var semantic: SemanticContext?
    var callSites: (([String: CallSiteScanner.SiteShape]) async -> [String: [SyntacticCallSite]])?
    /// A type's current source lines, which `T.deinit` is read out of: a deinit is never indexed, so that path too resolves to nothing under the type.
    var declarationSource: ((SymbolRow) -> [String]?)?
    var listCap = WhereRenderer.listCap
    var callSiteCap = WhereRenderer.callSiteCap
    /// Pages the sites by file in place of `callSiteCap`, for a `--refs` sweep with no index store, where they are the whole sweep there is.
    var paging: SyntacticSweepPaging?

    /// Whether `query` is a `T.init` naming a type that declares no init and is built by calling its name, whose sites this answers with.
    func buildsAnUndeclaredType(_ query: String) throws -> Bool {
        try types(for: query).contains { SameNamedTypes.isConstructed($0.row.kind) }
    }

    /// The body of the answer to `query` and the paths it cites, or `nil` unless it is a `T.init` query for types that declare no initializer.
    func answer(for query: String) async throws -> (body: [String], cited: [String])? {
        if let declarationSource, let deinits = try DeinitLookup(store: store, source: declarationSource).lookup(for: query) {
            return (DeinitLookup.whereLines(for: deinits, cap: listCap), deinits.cited)
        }
        let types = try types(for: query)
        guard !types.isEmpty else { return nil }
        let listed = types.prefix(listCap)
        var body = ["declarations (\(types.count)):"] + listed.map { $0.row.declarationLine(qualifiedName: $0.path, compact: false) }
        body += try listed.map { try provenance(of: $0.row, named: types.count > 1 ? $0.path : $0.row.name) }
        body += try await siteLines(for: types.filter { SameNamedTypes.isConstructed($0.row.kind) })
        return (body, listed.map(\.row.path))
    }

    /// The lines for the types a `T.init` query names that declare no initializer, beside `declarations`, the initializers it resolved to under other types of the name.
    func lines(beside declarations: [SymbolRow], for query: String) async throws -> [String] {
        guard declarations.contains(where: { $0.kind == .initializer }) else { return [] }
        let types = try types(for: query).filter { SameNamedTypes.isConstructed($0.row.kind) }
        guard !types.isEmpty else { return [] }
        var lines = ["", "declared with no init of their own (\(types.count)):"] + types.prefix(listCap).map { $0.row.declarationLine(qualifiedName: $0.path, compact: false) }
        lines += try types.prefix(listCap).map { try provenance(of: $0.row, named: $0.path) }
        return try await lines + siteLines(for: types)
    }

    /// The types a `T.init` query names that declare no initializer — every struct, class, enum, actor and protocol of the path — or empty where the query is not one.
    private func types(for query: String) throws -> [SameNamedTypes.Candidate] {
        let components = QualifiedPath.components(of: query)
        guard components.count > 1, let last = components.last, QualifiedPath.baseName(of: last) == "init" else { return [] }
        let qualifiers = Array(components.dropLast())
        let typeName = qualifiers.last ?? ""
        var named = try SameNamedTypes(store: store).candidates(named: typeName)
        // A protocol is no candidate for a site, but `P.init` names one as surely as a type, and is answered about it.
        named += try store.symbols(named: typeName).filter { $0.kind == .protocolKind }.map { row in
            try SameNamedTypes.Candidate(row: row, path: store.qualifiedName(of: row), parents: QualifiedPath.flattened(chain: store.parentChain(of: row).map(\.name)), initializers: [], unwritten: nil)
        }
        return named.filter { $0.initializers.isEmpty && QualifiedPath.matches(qualifiers: Array(qualifiers.dropLast()), chain: $0.parents, module: $0.row.module) }
    }

    /// The line saying who writes the initializers of `type`, a declaration that declares none, which the line calls `name`.
    private func provenance(of type: SymbolRow, named name: String) throws -> String {
        let opening = "\(name) declares no init — "
        switch type.kind {
        case .protocolKind:
            return "\(name) declares no init requirement — a protocol is never built itself; where \(type.name) lists the types conforming to it, whose inits are their own"
        case .structKind:
            return opening + "the compiler writes its memberwise initializer (and init(from:) where it is Decodable), which the calls below reach"
        case .enumKind:
            return opening + "any it has is compiler-written: init(rawValue:) for a raw-value enum, init(from:) for a Decodable one"
        case .classKind:
            guard let written = try store.inheritedNames(of: type.id).first else { break }
            let parent = String(written.prefix { $0 != "<" })
            let indexed = try store.symbols(named: parent)
            if indexed.contains(where: { $0.kind == .classKind }) {
                return opening + "it inherits \(parent)'s initializers, which the calls below reach; where \(parent).init lists them"
            }
            if !indexed.contains(where: { $0.kind == .protocolKind }) {
                return opening + "the calls below reach one it inherits from \(parent), if that is its superclass, or the default init() the compiler writes"
            }
        default:
            break
        }
        return opening + "the compiler writes its default init(), given every stored property has a default value"
    }

    /// The name-matched sites where the types are built, scanned for as their initializers' sites are — by the type's name — and each credited to the type of that name it builds.
    private func siteLines(for types: [SameNamedTypes.Candidate]) async throws -> [String] {
        guard let callSites, !types.isEmpty else { return [] }
        let byName = Dictionary(grouping: types, by: \.row.name)
        let scanned = await callSites(byName.mapValues { _ in .initializer })
        var lines = ["", "\(NameMatchedSites.headingOpening) over the working tree, never stale — see sift help answers (call sites)"]
        for name in byName.keys.sorted() {
            let asked = byName[name] ?? []
            let candidates = try SameNamedTypes(store: store).candidates(named: name)
            let attribution = try SameNamedTypes.StoreAttribution(store: store, semantic: candidates.count > 1 ? semantic : nil, candidates: candidates)
            let sites = try (scanned[name] ?? []).map { try (site: $0, owners: attribution.owners(of: $0)) }
            let spelled = sites.filter { $0.site.isListed(ownedBy: []) }
            for type in asked {
                // Only the index store's recorded reference sets a site apart; one the index reads from what is written as another type's, or as no type's, is kept and noted.
                let listed = spelled.filter { $0.owners.paths.contains(type.path) || !$0.owners.recorded }
                var reading = QualifierReadings(of: [type])
                for entry in listed {
                    reading.add(entry.site, owners: entry.owners, among: candidates, asked: [type.path])
                }
                let dropped = SameNamedTypes.dropped(another: spelled.count - listed.count, none: 0, named: name).joined(separator: ", ")
                let forType = asked.count > 1 ? " — for \(type.path)" : ""
                lines.append("")
                if listed.isEmpty {
                    lines.append(dropped.isEmpty
                        ? "no call spelled \"\(name).init\" anywhere in the working tree\(forType)"
                        : "no call spelled \"\(name).init\" builds \(type.path) — \(spelled.count) by name, \(dropped)")
                    continue
                }
                let fileCount = Set(listed.map(\.site.path)).count
                let files = "\(fileCount) file\(fileCount == 1 ? "" : "s")"
                let count = "\(listed.count) call site\(listed.count == 1 ? "" : "s")"
                // First, beside the count by name it qualifies.
                let counted = reading.clauses(named: name, listed: listed.map(\.site)) + (dropped.isEmpty ? [] : [dropped, "\(listed.count) kept"])
                lines.append(counted.isEmpty
                    ? "\"\(name).init\" (\(count) in \(files)\(forType)):"
                    : "\"\(name).init\" (\(spelled.count) call site\(spelled.count == 1 ? "" : "s") by name, \(counted.joined(separator: ", ")), in \(files)\(forType)):")
                let detail = { (site: SyntacticCallSite) -> String in
                    let owners = listed.first { $0.site == site }?.owners
                    return "in \(site.enclosing)" + (owners.map { SameNamedTypes.flag(of: $0, for: [type.path]) } ?? "")
                }
                if let paging {
                    lines += paging.rows(of: listed.map(\.site), detail: detail)
                    continue
                }
                lines += NameMatchedSites.rows(listed.prefix(callSiteCap).map(\.site), detail: detail)
                if listed.count > callSiteCap {
                    lines.append("    truncated: \(listed.count - callSiteCap) more call sites")
                }
            }
            // An implicit `.init call` or a `Self(x)` in an extension of a type declared elsewhere is kept only where its labels may reach an asked type's initializers: the compiler would refuse it on a type none of whose initializers take them, so the count says it was narrowed by them, as a declared initializer's does.
            let untold = sites.map(\.site).filter { site in
                guard !site.isListed(ownedBy: []) else { return false }
                guard let arguments = site.arguments else { return true }
                return asked.contains { $0.fits(arguments) != false }
            }
            lines += SyntacticCallerFallback.nameOnlyLines(untold, cap: callSiteCap, initializerOf: name, narrowed: true, grouped: true, paging: paging).map { "  " + $0 }
        }
        return lines
    }
}
