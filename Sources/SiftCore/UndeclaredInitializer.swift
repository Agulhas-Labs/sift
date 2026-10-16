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
    /// Where a files view (`where X --files`) records every type and site the answer lists, past its caps.
    var filesCollector: WhereFilesCollector?
    /// The declarations-only view (`where X --decl`): no call sites, and provenance sentences that do not point at them.
    var declarationsOnly = false
    /// The typealiases a call building a type may write in place of its name, which the type's own answer follows, so its sites are scanned for through them too.
    var initializerAliases: ((SymbolRow) throws -> SyntacticTypeUsage.InitializerAliases)?

    /// Whether `query` is a `T.init` naming a type that declares no init and is built by calling its name, whose sites this answers with.
    func buildsAnUndeclaredType(_ query: String) throws -> Bool {
        try types(for: query).contains { SameNamedTypes.isConstructed($0.row.kind) }
    }

    /// The body of the answer to `query` and the paths it cites, or `nil` unless it is a `T.init` query for types that declare no initializer.
    func answer(for query: String) async throws -> Answer? {
        if let declarationSource, let deinits = try DeinitLookup(store: store, source: declarationSource).lookup(for: query) {
            return Answer(body: DeinitLookup.whereLines(for: deinits, cap: listCap), cited: deinits.cited, declared: false)
        }
        let types = try types(for: query)
        guard !types.isEmpty else { return nil }
        let listed = types.prefix(listCap)
        recordDeclarations(of: types)
        filesCollector?.recordDeclarationsHeading("declarations (\(types.count)):")
        var body = ["declarations (\(types.count)):"] + listed.map { $0.row.declarationLine(qualifiedName: $0.path, compact: false) }
        body += try listed.map { try provenance(of: $0.row, named: types.count > 1 ? $0.path : $0.row.name) }
        if !declarationsOnly {
            body += try await siteLines(for: types.filter { SameNamedTypes.isConstructed($0.row.kind) })
        }
        return Answer(body: body, cited: listed.map(\.row.path), declared: true)
    }

    /// The lines for the types a `T.init` query names that declare no initializer, beside `declarations`, the initializers it resolved to under other types of the name.
    func lines(beside declarations: [SymbolRow], for query: String) async throws -> [String] {
        guard declarations.contains(where: { $0.kind == .initializer }) else { return [] }
        let types = try types(for: query).filter { SameNamedTypes.isConstructed($0.row.kind) }
        guard !types.isEmpty else { return [] }
        recordDeclarations(of: types)
        var lines = ["", "declared with no init of their own (\(types.count)):"] + types.prefix(listCap).map { $0.row.declarationLine(qualifiedName: $0.path, compact: false) }
        lines += try types.prefix(listCap).map { try provenance(of: $0.row, named: $0.path) }
        return try await lines + (declarationsOnly ? [] : siteLines(for: types))
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
            return opening + "the compiler writes its memberwise initializer (and init(from:) where it is Decodable)" + (declarationsOnly ? "" : ", which the calls below reach")
        case .enumKind:
            return opening + "any it has is compiler-written: init(rawValue:) for a raw-value enum, init(from:) for a Decodable one"
        case .classKind:
            guard let written = try store.inheritedNames(of: type.id).first else { break }
            let parent = String(written.prefix { $0 != "<" })
            let indexed = try store.symbols(named: parent)
            if indexed.contains(where: { $0.kind == .classKind }) {
                return opening + "it inherits \(parent)'s initializers" + (declarationsOnly ? "" : ", which the calls below reach") + "; where \(parent).init lists them"
            }
            if !indexed.contains(where: { $0.kind == .protocolKind }) {
                return opening + (declarationsOnly ? "it has one it inherits from \(parent), if that is its superclass, or the default init() the compiler writes" : "the calls below reach one it inherits from \(parent), if that is its superclass, or the default init() the compiler writes")
            }
        default:
            break
        }
        return opening + "the compiler writes its default init(), given every stored property has a default value"
    }

    /// Records the file of each of `types` as declaring one, past the list's cap; the heading names the query, not the types.
    private func recordDeclarations(of types: [SameNamedTypes.Candidate]) {
        for type in types {
            filesCollector?.recordDeclaration(path: type.row.path, owner: "\(type.path).init", isExtension: false)
        }
    }

    /// The name-matched sites where the types are built, scanned for as their initializers' sites are — by the type's name — and each credited to the type of that name it builds.
    private func siteLines(for types: [SameNamedTypes.Candidate]) async throws -> [String] {
        guard let callSites, !types.isEmpty else { return [] }
        let byName = Dictionary(grouping: types, by: \.row.name)
        let aliases = try initializerAliases.map { aliasesOf in try Dictionary(types.map { try ($0.row.id, aliasesOf($0.row)) }) { first, _ in first } } ?? [:]
        var request = byName.mapValues { _ in CallSiteScanner.SiteShape.initializer }
        for name in aliases.values.flatMap(\.names) {
            request[name] = CallSiteScanner.SiteShape.initializer.widened(by: request[name])
        }
        let scanned = await callSites(request)
        let spelledByName = scanned.mapValues { $0.filter { $0.isListed(ownedBy: []) } }
        var lines: [String] = []
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
                // A call written through a typealias of the type builds it as one spelling its name does, and is kept whatever its labels, as a direct call is here: the type may take an initializer the index cannot see, a protocol's from outside it (`SetAlgebra`'s array-literal initializer for an `OptionSet`) or a macro's.
                var typeAliases = aliases[type.row.id]
                let joined = try typeAliases?.joining(listed.map(\.site), from: spelledByName) ?? (sites: listed.map(\.site), through: [])
                let sites = joined.sites
                let byWrittenName = spelled.count + joined.through.count
                let dropped = SameNamedTypes.dropped(another: spelled.count - listed.count, none: 0, named: name)
                let aliasClauses = typeAliases?.clauses(for: joined.sites, through: joined.through, filesCollector: filesCollector) ?? []
                let forType = asked.count > 1 ? " — for \(type.path)" : ""
                lines.append("")
                if sites.isEmpty {
                    lines.append(dropped.isEmpty && aliasClauses.isEmpty
                        ? "no call spelled \"\(name).init\" anywhere in the working tree\(forType)"
                        : "no call spelled \"\(name).init\" builds \(type.path) — \(byWrittenName) by name, \((aliasClauses + dropped).joined(separator: ", "))")
                    continue
                }
                let fileCount = Set(sites.map(\.path)).count
                let files = "\(fileCount) file\(fileCount == 1 ? "" : "s")"
                let count = "\(sites.count) call site\(sites.count == 1 ? "" : "s")"
                // First, beside the count by name it qualifies.
                let counted = reading.clauses(named: name, listed: listed.map(\.site)) + aliasClauses + (dropped.isEmpty ? [] : dropped + ["\(sites.count) kept"])
                lines.append(counted.isEmpty
                    ? "\"\(name).init\" (\(count) by written name in \(files)\(forType)):"
                    : "\"\(name).init\" (\(byWrittenName) call site\(byWrittenName == 1 ? "" : "s") by written name, \(counted.joined(separator: ", ")), in \(files)\(forType)):")
                let detail = { (site: SyntacticCallSite) -> String in
                    let owners = listed.first { $0.site == site }?.owners
                    return "in \(site.enclosing)" + (owners.map { SameNamedTypes.flag(of: $0, for: [type.path]) } ?? "")
                }
                filesCollector?.recordSites(sites)
                if let paging {
                    lines += paging.rows(of: sites, detail: detail)
                    continue
                }
                lines += NameMatchedSites.rows(Array(sites.prefix(callSiteCap)), detail: detail)
                if sites.count > callSiteCap {
                    lines.append("    truncated: \(sites.count - callSiteCap) more call sites")
                }
            }
            // An implicit `.init call` or a `Self(x)` in an extension of a type declared elsewhere is kept only where its labels may reach an asked type's initializers: the compiler would refuse it on a type none of whose initializers take them, so the count says it was narrowed by them, as a declared initializer's does.
            let untold = sites.map(\.site).filter { site in
                guard !site.isListed(ownedBy: []) else { return false }
                guard let arguments = site.arguments else { return true }
                return asked.contains { $0.fits(arguments) != false }
            }
            filesCollector?.recordSites(untold)
            lines += SyntacticCallerFallback.nameOnlyLines(untold, cap: callSiteCap, initializerOf: name, narrowed: true, grouped: true, paging: paging).map { "  " + $0 }
        }
        return lines
    }
}

extension UndeclaredInitializer {
    /// An answer's lines and the paths it cites; `declared` is false for a `deinit`'s answer, which has no declarations block.
    struct Answer {
        let body: [String]
        let cited: [String]
        let declared: Bool
    }
}
