//
// Copyright © Agulhas Labs
//

import Foundation

/// The `@T` sites of a property wrapper's initializers that the index store records no call at, found by name to stand beside the store's answer.
///
/// The store records a wrapper written on a stored property or on a closure's parameter as a call of the initializer it resolves to, and may record no call for one written on a function's parameter, so an answer read from the store alone can say "no callers" of a wrapper used only there. Only these attribute sites are added, never the name scan's other sites, and only at lines where the store records a reference to the wrapper type itself and no call of any of its initializers, so a same-named type's attribute is never taken for this one's where the store can judge the line. A call passing `$label:` to a parameter declared with the wrapper runs its `init(projectedValue:)` where the call is written, which the store records no call of either, so those calls are added too, only where the store resolves the parameter's own attribute to this type. A site in a file written since the build is judged by no line the store holds for that file, so a call there, and an attribute there, is kept unjudged, and the file heads the answer stale.
///
/// Each site is given to the one initializer its written labels reach, and a site whose labels reach none of them, or more than one, is listed once for the type, so one query never lists a site twice.
struct WrapperAttributeSites {
    /// The sites given to each asked initializer, by the initializer's row id.
    private(set) var assigned: [Int64: [SyntacticCallSite]] = [:]
    /// The sites no one initializer's labels reach, by the id of the first asked initializer of their type, which they are listed after.
    private(set) var unassigned: [Int64: [SyntacticCallSite]] = [:]
    /// The module-qualified path of the wrapper type each asked initializer belongs to, by the initializer's row id.
    private(set) var types: [Int64: String] = [:]
    /// The repo-relative files whose store facts decided a site's listing, by the wrapper type's module-qualified path: each site's own file and each file declaring a parameter a `$label:` call may be passed to.
    private(set) var reliedOn: [String: Set<String>] = [:]

    /// Whether a site is listed that could be a call of `row`, which is then never answered "no callers".
    func hasSites(for row: SymbolRow) -> Bool {
        guard let path = types[row.id] else { return false }
        return assigned[row.id]?.isEmpty == false || types.contains { id, other in other == path && unassigned[id]?.isEmpty == false }
    }

    /// The blocks `where` lists after the store's answer for `row`, which it names `owner`: its own sites, then its type's unassigned ones where it is the first of that type asked.
    ///
    /// Every file the listing relied on is put to `occurrences`, so an answer that dropped or kept a site on a store fact from a file written since the build is headed stale rather than fresh, and a site in such a file carries the mark the store's own rows there do.
    func lines(for row: SymbolRow, owner: String, cap: Int, judgedBy occurrences: OccurrenceFreshness, under root: URL) -> [String] {
        guard let path = types[row.id] else { return [] }
        for relied in (reliedOn[path] ?? []).sorted() {
            _ = occurrences.state(of: root.appendingPathComponent(relied).path)
        }
        let type = DeclaredTypeName.last(ofPath: path)
        let marker = { (site: SyntacticCallSite) in occurrences.state(of: root.appendingPathComponent(site.path).path).marker ?? "" }
        return Self.lines(assigned[row.id] ?? [], named: type, for: owner, cap: cap, grouped: true, marker: marker)
            + Self.lines(unassigned[row.id] ?? [], named: type, for: Self.unassignedOwner(path), cap: cap, grouped: true, marker: marker)
    }

    /// The sites `lines(for:owner:cap:judgedBy:under:)` lists for `row` within `cap`, which the name scan beside a refused initializer then lists no second time.
    ///
    /// A site past the cap is only counted there, so it is left for the name scan to list.
    func sites(for row: SymbolRow, cap: Int) -> [SyntacticCallSite] {
        types[row.id] == nil ? [] : Array((assigned[row.id] ?? []).prefix(cap) + (unassigned[row.id] ?? []).prefix(cap))
    }

    /// What an unassigned block is said to be for: the type, since the site's labels choose none of its initializers.
    static func unassignedOwner(_ type: String) -> String {
        "\(type), no one initializer by its labels"
    }

    /// The unrecorded attribute sites of the property-wrapper types `rows`' initializers belong to, as `find(for:in:callSites:recorded:modifiedSinceBuild:)` gives them, judged by `context`'s stores.
    static func find(
        for rows: some Sequence<SymbolRow>,
        in store: IndexStore,
        callSites: (([String: CallSiteScanner.SiteShape]) async -> [String: [SyntacticCallSite]])?,
        context: SemanticContext
    ) async throws -> WrapperAttributeSites {
        try await find(for: rows, in: store, callSites: callSites) { row in
            context.owner(of: row).map { owned in Set(owned.context.store.callers(ofUSR: owned.usr).map { "\(owned.context.relativePath($0.path)):\($0.line):\($0.column)" }) }
        } modifiedSinceBuild: { path in
            ((try? store.fileRow(path: path))?.mtime ?? 0) > context.buildAnchor
        }
    }

    /// The unrecorded attribute sites of the property-wrapper types `rows`' initializers belong to, from one scan over the working tree, where `recorded` gives the `path:line:column` of every reference the store records to a symbol, or `nil` where no store resolves it, and `modifiedSinceBuild` says whether a repo-relative file was written since the build.
    static func find(
        for rows: some Sequence<SymbolRow>,
        in store: IndexStore,
        callSites: (([String: CallSiteScanner.SiteShape]) async -> [String: [SyntacticCallSite]])?,
        recorded: (SymbolRow) -> Set<String>?,
        modifiedSinceBuild: (String) -> Bool
    ) async throws -> WrapperAttributeSites {
        var answer = WrapperAttributeSites()
        var asked: [String: [SymbolRow]] = [:]
        var declarations: [String: SymbolRow] = [:]
        var order: [String] = []
        for row in rows where answer.types[row.id] == nil {
            guard let (path, declaration) = try wrapperType(of: row, in: store) else { continue }
            answer.types[row.id] = path
            if declarations.updateValue(declaration, forKey: path) == nil {
                order.append(path)
            }
            asked[path, default: []].append(row)
        }
        guard let callSites, !order.isEmpty else { return WrapperAttributeSites() }
        let found = await callSites(Dictionary(uniqueKeysWithValues: Set(order.map(DeclaredTypeName.last(ofPath:))).map { ($0, CallSiteScanner.SiteShape.initializer) }))
        for path in order {
            guard let declaration = declarations[path], let rows = asked[path], let first = rows.first else { continue }
            let candidates = found[DeclaredTypeName.last(ofPath: path)]?.filter { $0.isAttribute || $0.projection != nil } ?? []
            guard !candidates.isEmpty else { continue }
            let initializers = try initializers(of: declaration, at: path, in: store)
            let calls = Dictionary(uniqueKeysWithValues: initializers.map { ($0.id, Set((recorded($0) ?? []).map(Self.line(of:)))) })
            let called = calls.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            let referenced = Set((recorded(declaration) ?? []).map(Self.line(of:)))
            for candidate in candidates {
                let location = "\(candidate.path):\(candidate.line)"
                let reached = initializers.filter { !SyntacticCallerFallback.LabelNarrowed.reaching([candidate], by: [$0]).isEmpty }
                let site: SyntacticCallSite
                answer.reliedOn[path, default: []].insert(candidate.path)
                if let projection = candidate.projection {
                    answer.reliedOn[path, default: []].formUnion(projection.parameters.map(\.path))
                    // Unrecorded only where no initializer it reaches is called on its line: the line may hold other calls.
                    guard !reached.contains(where: { calls[$0.id]?.contains(location) == true }),
                          let kept = try Self.projected(candidate, resolving: referenced.union(called), in: store, recorded: recorded, modifiedSinceBuild: modifiedSinceBuild) else { continue }
                    site = kept
                } else if modifiedSinceBuild(candidate.path) {
                    // The store's lines no longer say where this file's references are, nor which of them an attribute
                    // written since the build is, so every attribute is kept unjudged, qualifier or not (a typealias of the
                    // owner makes `@Wrap.T` the owner's `T`): one the store's own row may list too is listed twice, where
                    // dropping it could hide one.
                    site = candidate
                } else {
                    guard referenced.contains(location), !called.contains(location) else { continue }
                    site = candidate
                }
                if reached.count == 1, let initializer = reached.first {
                    if rows.contains(where: { $0.id == initializer.id }) {
                        answer.assigned[initializer.id, default: []].append(site)
                    }
                } else {
                    answer.unassigned[first.id, default: []].append(site)
                }
            }
        }
        return answer
    }

    /// The name-matched block listed after the store's answer for `owner`, headed as every name-matched block is so it is never read as resolved.
    ///
    /// `grouped` lists each file's path once with its rows under it, as `where` lists every name-matched site, under a short heading pointing at the rule in `sift help answers` (call sites); `diff` keeps a path on each row and keeps the full heading, since `diff` output is never rewritten once written.
    static func lines(
        _ sites: [SyntacticCallSite],
        named type: String,
        for owner: String,
        cap: Int,
        grouped: Bool = false,
        marker: (SyntacticCallSite) -> String = { _ in "" }
    ) -> [String] {
        guard !sites.isEmpty else { return [] }
        let fileCount = Set(sites.map(\.path)).count
        let count = sites.count == 1 ? "1 call site" : "\(sites.count) call sites"
        let heading = grouped
            ? "\(NameMatchedSites.headingOpening) where the index store records no call — see sift help answers (call sites)"
            : "\(NameMatchedSites.headingOpening) where the index store records no call: each is a property wrapper's @T attribute, which calls its initializer, on a line where the store records the type and no call of its initializers, as on a function's parameter; a name is not a symbol, so verify a hit — see sift help answers"
        var lines = [
            "",
            heading,
            "\"@\(type)\" (\(count) in \(fileCount) file\(fileCount == 1 ? "" : "s") — for \(owner)):",
        ]
        if grouped {
            lines += NameMatchedSites.rows(sites.prefix(cap)) { "in \($0.enclosing)\($0.projection?.flag ?? "")\(marker($0))" }
        } else {
            for site in sites.prefix(cap) {
                lines.append("  \(site.path):\(site.line)  in \(site.enclosing)\(site.projection?.flag ?? "")\(marker(site))")
            }
        }
        if sites.count > cap {
            let indent = grouped ? "    " : "  "
            lines.append("\(indent)truncated: \(sites.count - cap) more call sites")
        }
        return lines
    }
}

private extension WrapperAttributeSites {
    /// The module-qualified path and declaration of the type an initializer belongs to, where that type is declared `@propertyWrapper`, or `nil` for anything else.
    static func wrapperType(of row: SymbolRow, in store: IndexStore) throws -> (String, SymbolRow)? {
        guard row.kind == .initializer else { return nil }
        let qualified = try store.qualifiedName(of: row)
        guard qualified.hasSuffix("." + row.name) else { return nil }
        let path = String(qualified.dropLast(row.name.count + 1))
        let declaration = try store.typeDeclarations(named: DeclaredTypeName.last(ofPath: path)).first { declaration in
            try declaration.signature.split(whereSeparator: \.isWhitespace).contains("@propertyWrapper") && store.qualifiedName(of: declaration) == path
        }
        return declaration.map { (path, $0) }
    }

    /// The `$label:` call `site` as listed beside the store's answer, or `nil` where it is another type's or another declaration's.
    ///
    /// It is this type's where the store resolves a parameter's `@T` to the type — the attribute's line is in `resolved` — and records a call of that parameter's own declaration where the site names it, and is then listed unflagged, since the store has said which declaration it calls. It is kept as the scan found it, flag and all, where the store cannot judge it: a file it would be judged by was written since the build, or no store resolves the declaration.
    static func projected(
        _ site: SyntacticCallSite,
        resolving resolved: Set<String>,
        in store: IndexStore,
        recorded: (SymbolRow) -> Set<String>?,
        modifiedSinceBuild: (String) -> Bool
    ) throws -> SyntacticCallSite? {
        guard let projection = site.projection else { return nil }
        for parameter in projection.parameters {
            if modifiedSinceBuild(site.path) || modifiedSinceBuild(parameter.path) {
                return site
            }
            guard resolved.contains(parameter.declaredAt) else { continue }
            let declaration = try store.symbols(inFile: parameter.path)
                .filter { ($0.kind == .function || $0.kind == .initializer) && ($0.line ... max($0.line, $0.endLine)).contains(parameter.line) }
                .max { $0.line < $1.line }
            guard let declaration, let calls = recorded(declaration) else { return site }
            // Where the call is made through a name, the store's column tells it from another call of the name on its line.
            let made = site.calleeAt.map { calls.contains("\(site.path):\($0)") } ?? calls.contains { Self.line(of: $0) == "\(site.path):\(site.line)" }
            if made {
                return site.projecting(ProjectedCall(parameters: [parameter], otherWrappers: []))
            }
        }
        return nil
    }

    /// The `path:line` of a `path:line:column` the store records.
    static func line(of position: String) -> String {
        String(position[..<(position.lastIndex(of: ":") ?? position.endIndex)])
    }

    /// The initializers the type at `path` declares, in its body or in an extension of it.
    static func initializers(of declaration: SymbolRow, at path: String, in store: IndexStore) throws -> [SymbolRow] {
        var members = try store.children(of: declaration.id)
        for extended in try store.extensions(ofTypeNamed: DeclaredTypeName.last(ofPath: path)) {
            members += try store.children(of: extended.id)
        }
        return try members.filter { member in
            try member.kind == .initializer && store.qualifiedName(of: member) == path + "." + member.name
        }
    }
}
