//
// Copyright © Agulhas Labs
//

import Foundation

/// Who calls the members a range removed or changed the signature of — the question a reviewer asks of exactly those, answered by the machinery `where` answers it with.
///
/// Resolved from the index store where the store can answer for the declaration today; otherwise name-matched over the working tree, and labelled as that — a different kind of claim, not a weaker version of the same one. A removed member always takes the second road: it has no declaration left to resolve, and what still spells its name is precisely what the removal may have broken.
///
/// Both roads read the working tree **as it stands**, which is the after side only when the range ends at the working tree — the answer says so whenever it does not.
struct DiffCallers {
    let store: IndexStore
    let repoRoot: URL
    let enumerator: FileEnumerator
}

extension DiffCallers {
    /// Members listed before the rest are counted instead.
    static var memberCap: Int {
        20
    }

    /// Sites listed per member before the rest are counted instead — `where` lists them all.
    static var siteCap: Int {
        8
    }

    /// One member the section asks about.
    struct Target: Sendable {
        let label: String
        let name: String
        let kind: SymbolKind
        /// Where the declaration is written on the range's after side (the before side for a removal) — the path and line that choose among same-named rows, since overloads can share a labeled name.
        let path: String
        let line: Int
        let removed: Bool
    }

    /// What was found for one member, and how.
    struct Report: Sendable {
        let target: Target
        /// `nil` when the index store resolved it; otherwise why it did not, which is also why these are name matches.
        let unresolvedBecause: String?
        /// The base name the sites were matched on — `nil` for a subscript, whose uses are `x[…]` and spell no name to match.
        let searchedName: String?
        let sites: [Site]
        /// The places a name-matched function is written by name with no call and not listed — `f`, `x.f`, another type's `T.f` — shown, as `where` shows them, only where no site is.
        var nameOnly: [SyntacticCallSite] = []
        /// A resolved initializer's `@T` attribute sites the index store records no call at — a wrapper on a function's parameter — found by name to stand beside the store's answer.
        var wrapperSites: [SyntacticCallSite] = []
        /// The `@T` sites of this initializer's wrapper type whose labels reach no one of its initializers, listed once, after the first of the type's changed initializers.
        var unassignedWrapperSites: [SyntacticCallSite] = []
        /// The module-qualified path of the wrapper type the unassigned sites are for, which heads their block as `where` does.
        var wrapperTypePath: String?
        /// The repo-relative files the wrapper sites listing relied on that were written since the build, whose sites are marked so.
        var staleFiles: Set<String> = []
    }

    struct Site: Sendable {
        let path: String
        let line: Int
        let enclosing: String
        let marker: String
        /// The property wrapper's sibling a property's use went through — `$flag` — so a diff lists it as `where` does; `nil` otherwise.
        let through: String?
    }

    /// Only a member something can call, read or name: a function, an initializer, a subscript, a property, an enum case.
    static func isCallable(_ kind: SymbolKind) -> Bool {
        switch kind {
        case .function, .initializer, .subscriptKind, .variable, .enumCase: true
        default: false
        }
    }

    /// Which of the index's rows for a name, in the target's file and under its container, is the target — or why none can be said to be.
    enum Choice {
        case row(SymbolRow)
        case fallback(String)
    }

    /// Picks the target's own declaration among same-named rows: the only one, or the one at its line.
    ///
    /// Overloads can share a labeled name (`f(_:)` taking an `Int` and one taking a `String`) and only the line tells them apart; taking the first would print one overload's callers as resolved for the other.
    static func declaration(among rows: [SymbolRow], for target: Target) -> Choice {
        guard !rows.isEmpty else {
            return .fallback("not found in the index as it stands")
        }
        let atLine = rows.count == 1 ? rows : rows.filter { $0.line == target.line }
        guard atLine.count == 1, let row = atLine.first else {
            let which = atLine.isEmpty ? "none of them is" : "\(atLine.count) of them are"
            return .fallback("\(rows.count) declarations share this name in \(target.path), and in the index as it stands \(which) at line \(target.line)")
        }
        return .row(row)
    }

    func reports(for targets: [Target], semantic: SemanticInput) async throws -> [Report] {
        var resolved: [Int: [Site]] = [:]
        var reasons: [Int: String] = [:]
        var resolvedRows: [Int: SymbolRow] = [:]
        for (index, target) in targets.enumerated() {
            switch try resolve(target, semantic: semantic) {
            case let .sites(sites, row):
                resolved[index] = sites
                resolvedRows[index] = row
            case let .fallback(reason): reasons[index] = reason
            }
        }
        // A wrapper written on a function's parameter is a call the store never records, so a resolved initializer's answer needs the same name-matched check `where` runs, or it reports "0 call sites" of a wrapper used only there.
        var wrapperSites = WrapperAttributeSites()
        var judge: OccurrenceFreshness?
        if case let .active(context) = semantic, !resolvedRows.isEmpty {
            let scanner = CallSiteScanner(repoRoot: repoRoot, enumerator: enumerator)
            wrapperSites = try await WrapperAttributeSites.find(
                for: resolvedRows.sorted { $0.key < $1.key }.map(\.value),
                in: store,
                callSites: { await scanner.callSites(named: $0) },
                recorded: { row in
                    guard let usr = context.store.usr(for: row) else { return nil }
                    return Set(context.store.callers(ofUSR: usr).map { "\(context.relativePath($0.path)):\($0.line):\($0.column)" })
                },
                modifiedSinceBuild: { path in ((try? store.fileRow(path: path))?.mtime ?? 0) > context.buildAnchor }
            )
            judge = OccurrenceFreshness(store: store, buildAnchor: context.buildAnchor, relativePath: context.relativePath)
        }
        /// The files a resolved initializer's wrapper listing relied on that were written since the build.
        func staleFiles(of row: SymbolRow?) -> Set<String> {
            guard let judge, let row, let type = wrapperSites.types[row.id] else { return [] }
            let relied = wrapperSites.reliedOn[type] ?? []
            return relied.filter { judge.state(of: repoRoot.appendingPathComponent($0).path) == .modifiedSinceBuild }
        }
        /// A subscript is used as `x[…]`, which spells no name, so it has nothing to scan for: a scan for "subscript" would count zero sites of something used everywhere.
        ///
        /// An initializer is called through its type, so its sites are matched on the type's name.
        func searchedName(of target: Target) -> String? {
            let containers = QualifiedPath.components(of: target.label).dropLast()
            if target.kind == .initializer, !containers.isEmpty {
                return DeclaredTypeName.last(ofPath: containers.joined(separator: "."))
            }
            return target.kind == .subscriptKind ? nil : CallSiteScanner.baseName(of: target.name)
        }
        var shapes: [String: CallSiteScanner.SiteShape] = [:]
        for (index, target) in targets.enumerated() where reasons[index] != nil {
            guard let base = searchedName(of: target) else { continue }
            shapes[base] = .of(target.kind, sharing: shapes[base])
        }
        let scanned = shapes.isEmpty ? [:] : await CallSiteScanner(repoRoot: repoRoot, enumerator: enumerator).callSites(named: shapes)
        return targets.enumerated().map { index, target in
            let base = searchedName(of: target)
            if let sites = resolved[index] {
                let row = resolvedRows[index]
                return Report(
                    target: target,
                    unresolvedBecause: nil,
                    searchedName: base,
                    sites: sites,
                    wrapperSites: row.flatMap { wrapperSites.assigned[$0.id] } ?? [],
                    unassignedWrapperSites: row.flatMap { wrapperSites.unassigned[$0.id] } ?? [],
                    wrapperTypePath: row.flatMap { wrapperSites.types[$0.id] },
                    staleFiles: staleFiles(of: row)
                )
            }
            let owners = Self.owners(of: target)
            let (listed, nameOnly) = (base.flatMap { scanned[$0] } ?? []).reduce(into: ([SyntacticCallSite](), [SyntacticCallSite]())) { split, site in
                if site.isListed(ownedBy: owners) {
                    split.0.append(site)
                } else {
                    split.1.append(site)
                }
            }
            let sites = listed.map { Site(path: $0.path, line: $0.line, enclosing: $0.enclosing, marker: "", through: nil) }
            return Report(target: target, unresolvedBecause: reasons[index], searchedName: base, sites: sites, nameOnly: nameOnly)
        }
    }
}

private extension DiffCallers {
    enum Resolution {
        case sites([Site], row: SymbolRow)
        case fallback(String)
    }

    /// The simple name of the type declaring a function target — `Engine` for `Engine.fast(level:)` — on which a bare `T.f` handed to a call is one of its sites; none for anything else.
    static func owners(of target: Target) -> Set<String> {
        let containers = QualifiedPath.components(of: target.label).dropLast()
        guard target.kind == .function, !containers.isEmpty else { return [] }
        return [DeclaredTypeName.last(ofPath: containers.joined(separator: "."))]
    }

    /// The store's callers for one member, or why the store cannot give them — on the same rules `where` refuses by.
    func resolve(_ target: Target, semantic: SemanticInput) throws -> Resolution {
        if target.removed {
            return .fallback("removed, so there is no declaration left to resolve")
        }
        guard case let .active(context) = semantic else {
            return .fallback("no index store is in use")
        }
        let components = QualifiedPath.components(of: target.label)
        let qualifiers = Array(components.dropLast())
        let rows = try store.symbols(named: components.last ?? target.name).filter { row in
            try row.path == target.path && QualifiedPath.matches(qualifiers: qualifiers, chain: store.parentChain(of: row).map(\.name), module: row.module)
        }
        let row: SymbolRow
        switch Self.declaration(among: rows, for: target) {
        case let .row(chosen): row = chosen
        case let .fallback(reason): return .fallback(reason)
        }
        let mtime = try store.fileRow(path: row.path)?.mtime ?? 0
        if mtime > context.buildAnchor {
            return .fallback("its file changed since the last build")
        }
        guard let usr = context.store.usr(for: row) else {
            return .fallback("no build covers its file")
        }
        let occurrences = OccurrenceFreshness(store: store, buildAnchor: context.buildAnchor, relativePath: context.relativePath)
        // A property or subscript is read and written, never called: its callers are empty however much it is used.
        // An enum case is named, and called only where a payload is built: its callers are a fraction of its uses.
        let hits = if row.kind.isReadAndWritten {
            WhereRenderer.collapsedUses(context.store.uses(ofUSR: usr)).map(\.hit)
        } else if row.kind == .enumCase {
            WhereRenderer.collapsedUses(context.store.caseUses(ofUSR: usr)).map(\.hit)
        } else {
            WhereRenderer.collapsedIdentical(context.store.callers(ofUSR: usr)).map(\.hit)
        }
        // A reference with no call says so, as `where` marks it, so a function handed on unapplied is not read as called.
        return .sites(hits.map { hit in
            let marker = (hit.uncalled ? " — referenced, not called" : "") + (occurrences.state(of: hit.path).marker ?? "")
            return Site(path: context.relativePath(hit.path), line: hit.line, enclosing: hit.name, marker: marker, through: hit.through)
        }, row: row)
    }
}
