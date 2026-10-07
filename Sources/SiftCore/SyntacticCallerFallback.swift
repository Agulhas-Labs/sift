//
// Copyright © Agulhas Labs
//

/// `where`'s degraded, name-matched answer for the symbols semantics left unanswered — split out of `WhereRenderer` to keep that file under the line cap.
struct SyntacticCallerFallback {
    /// Name-matched call sites for the symbols semantics left unanswered.
    ///
    /// The refusal above these lines is still right — a stale index store must not be allowed to claim a resolved fact. But a refusal alone would be the *whole* answer, and "build the project" costs minutes in a monorepo, which lands hardest exactly where the question is most common: test files change most and are built least, so they refuse most, and "who calls this helper" is a test-file question.
    ///
    /// So the answer degrades instead of vanishing. This block is deliberately spelled as a different kind of claim, not a weaker version of the same one: it says which name it matched, that a name is not a symbol, and what that costs in both directions — unrelated same-named members are included, and so are local variables and parameters of the name, which a property's uses match wherever they are read; dynamically dispatched calls are missed. It is a lead to verify, not a resolved fact, and it never touches the semantic axis in the header.
    ///
    /// `sameNamed`, given, flags an initializer's sites that may build another type sharing its type's simple name (``SameNamedTypes``), and notes beside the count those whose qualifier the index reads as another type's owner or as declaring no type of the name, which are kept all the same (``QualifierReadings``).
    ///
    /// `listedAbove` says whether a site is already listed in the store's answers for the other declarations, where it is counted rather than listed a second time.
    ///
    /// `paging`, given for a `--refs` sweep with no index store, pages every list here by file instead of capping it at `callSiteCap`: the sites are then the whole sweep there is.
    ///
    /// `memberwise` counts the calls passing a stored property by its label to its struct's memberwise initializer, which a rename changes too, so a property with no use by name is never said to have none; with `paging`, or in a `--refs` answer that is no sweep (as with `--syntactic`), it lists them with the property's uses, and otherwise says `--refs` lists them.
    ///
    /// `receivers`, given for a qualified query, answers for the types the named members belong to whether a call site may reach them, or `nil` where a call on any type may; a site it rules out is another type's own and is dropped and counted.
    static func lines(
        for rows: [SymbolRow],
        declaredAs declarations: [SymbolRow],
        callSites: (([String: CallSiteScanner.SiteShape]) async -> [String: [SyntacticCallSite]])?,
        callSiteCap: Int,
        listedAbove: (SyntacticCallSite) -> Bool = { _ in false },
        initializerLabelsWereNamed: Bool = false,
        qualifiedName: (SymbolRow) throws -> String,
        receivers: ((Set<String>) throws -> ((SyntacticCallSite) throws -> ReceiverReach)?)? = nil,
        sameNamed: SameNamedTypes? = nil,
        paging: SyntacticSweepPaging? = nil,
        memberwise: MemberwiseLabelSites? = nil,
        listsLabelCalls: Bool = false
    ) async throws -> [String] {
        guard let callSites, !rows.isEmpty else { return [] }
        // Each declaration's signature is printed once, in the list above this block, so the block names the ones it
        // stands for as briefly as stays unambiguous.
        let names = try DeclarationShortNames(declarations, qualifiedName: qualifiedName)
        var askedByBase: [String: [SymbolRow]] = [:]
        /// The simple name of the type a declaration belongs to, or `nil` for one declared outside any.
        func owner(of row: SymbolRow) throws -> String? {
            let qualified = try qualifiedName(row)
            guard qualified.hasSuffix("." + row.name) else { return nil }
            return DeclaredTypeName.last(ofPath: qualified.dropLast(row.name.count + 1))
        }
        // An initializer is called through its type rather than by its own name, so its sites are scanned for by the
        // type's name and listed as `Box.init`, apart from every other type's; anything else by its base name.
        var scannedAs: [String: String] = [:]
        func base(of row: SymbolRow) throws -> String {
            let base = CallSiteScanner.baseName(of: row.name)
            guard row.kind == .initializer, let owner = try owner(of: row) else { return base }
            scannedAs[owner + "." + base] = owner
            return owner + "." + base
        }
        // Narrowed by every declaration of the name, not only the few asked of the store: a call of one past that
        // cap is still a call the name's list stands for.
        let rowsByBase = try Dictionary(grouping: declarations, by: base(of:))
        // The simple name of the type each declaration belongs to, where `Self.run(x)` may name the method unapplied.
        var ownersByBase: [String: Set<String>] = [:]
        // The same for the name's functions alone, where a bare `T.f` handed to a call is one of their sites: on a
        // type declaring a same-named case or property it is that case or property.
        var functionOwnersByBase: [String: Set<String>] = [:]
        // The module-qualified path of the type each initializer belongs to, which a qualified `@M.T` must name.
        var initializedPathsByBase: [String: Set<String>] = [:]
        for row in declarations {
            guard let owner = try owner(of: row) else { continue }
            try ownersByBase[base(of: row), default: []].insert(owner)
            if row.kind == .initializer {
                let qualified = try qualifiedName(row)
                try initializedPathsByBase[base(of: row), default: []].insert(String(qualified.dropLast(row.name.count + 1)))
            }
            if row.kind == .function {
                try functionOwnersByBase[base(of: row), default: []].insert(owner)
            }
        }
        var shapes: [String: CallSiteScanner.SiteShape] = [:]
        // A subscript is used as `x[…]`, which spells no name, so no site of one can be found by name: a scan for
        // "subscript" finds nothing however much it is used, and "no call spelled" said of it reads as dead code.
        var unnameable: [SymbolRow] = []
        for row in rows {
            guard row.kind != .subscriptKind else {
                unnameable.append(row)
                continue
            }
            let base = try base(of: row)
            askedByBase[base, default: []].append(row)
            shapes[base] = .of(row.kind, sharing: shapes[base])
        }
        var request: [String: CallSiteScanner.SiteShape] = [:]
        for (base, shape) in shapes {
            let name = scannedAs[base] ?? base
            request[name] = shape.widened(by: request[name])
        }
        for type in memberwise?.typeNames ?? [] {
            request[type] = CallSiteScanner.SiteShape.initializer.widened(by: request[type])
        }
        // The header disclaims a list matched on a name, so only a scan that had a name to match gets one: over a
        // subscript alone it would disclaim hits of a match that never ran.
        var lines: [String] = []
        let sitesByName = askedByBase.isEmpty ? [:] : await callSites(request)
        // A site is kept, and flagged where its labels or scope say it may build another type sharing the initialized
        // type's name. One the index reads, from what is written, as another type's or as no type's is kept all the
        // same and noted beside the count: reading a qualifier from the index alone is not sound.
        let resolver = try sameNamed.map { try SameNamedTypes.Resolver(store: $0.store) }
        var scanned: [String: [SyntacticCallSite]] = [:]
        var qualifiedElsewhere: [String: Int] = [:]
        var ambiguity: [String: [(site: SyntacticCallSite, flag: String)]] = [:]
        var readings: [String: QualifierReadings] = [:]
        for base in shapes.keys {
            guard let sites = sitesByName[scannedAs[base] ?? base] else { continue }
            let paths = initializedPathsByBase[base] ?? []
            var candidates: [SameNamedTypes.Candidate] = []
            if let type = scannedAs[base], let sameNamed, !paths.isEmpty {
                candidates = try sameNamed.candidates(named: type, onlyShared: !sites.contains { $0.qualifier != nil })
                candidates = paths.isSubset(of: candidates.map(\.path)) ? candidates : []
            }
            var reading = QualifierReadings(of: candidates.filter { paths.contains($0.path) })
            scanned[base] = try sites.filter { site in
                guard let resolver, !candidates.isEmpty, !site.isAttribute else {
                    reading.add(site, owners: nil, among: candidates, asked: paths)
                    // A qualified `@M.T` that spells no owner of T is kept and noted, not dropped: a typealias of the owner,
                    // a supertype or anything the scan never writes down makes Swift read it as the owner's own T.
                    if site.isAttribute, site.qualifier != nil, !paths.contains(where: { attribute(site, mayNamePath: $0) }),
                       site.isListed(ownedBy: functionOwnersByBase[base] ?? [])
                    {
                        qualifiedElsewhere[base, default: 0] += 1
                    }
                    return true
                }
                let owners = try resolver.owners(of: site, among: candidates)
                reading.add(site, owners: owners, among: candidates, asked: paths)
                let flag = SameNamedTypes.flag(of: owners, for: paths)
                if !flag.isEmpty {
                    ambiguity[base, default: []].append((site, flag))
                }
                return true
            }
            readings[base] = reading
        }
        let found = scanned.reduce(into: [String: [SyntacticCallSite]]()) { found, entry in
            found[entry.key] = entry.value.filter { $0.isListed(ownedBy: functionOwnersByBase[entry.key] ?? []) }
        }
        /// Whether a call of `base` may reach its declarations, where the query named the type they belong to.
        func reaching(_ base: String) throws -> ((SyntacticCallSite) throws -> ReceiverReach)? {
            guard let receivers, let rows = rowsByBase[base], try rows.allSatisfy({ try owner(of: $0) != nil }) else { return nil }
            return try receivers(ownersByBase[base] ?? [])
        }
        /// Whether every declaration of `base` is a member of a type that needs an instance — no static member, case or initializer — which an unchained `.m(x)` never calls.
        func isInstanceOnly(_ base: String) throws -> Bool {
            guard let rows = rowsByBase[base], !rows.isEmpty else { return false }
            return try rows.allSatisfy { row in
                try !row.isStatic && [.function, .variable, .subscriptKind].contains(row.kind) && owner(of: row) != nil
            }
        }
        let kept = found.reduce(into: [String: LabelNarrowed]()) { kept, entry in
            guard shapes[entry.key] != .use,
                  let narrowed = LabelNarrowed(
                      entry.value,
                      by: rowsByBase[entry.key] ?? [],
                      ownedBy: ownersByBase[entry.key] ?? [],
                      initializerLabelsWereNamed: initializerLabelsWereNamed
                  )
            else { return }
            kept[entry.key] = narrowed
        }
        if !askedByBase.isEmpty {
            // "over the working tree" is a substitution point: a lookup at a past revision replaces it with
            // the files parsed there, since that scan never ran over the working tree at all.
            var header = "\(NameMatchedSites.headingOpening) over the working tree, never stale"
            if kept.values.contains(where: \.droppedAnySite) {
                header += "; labels narrowed"
            }
            header += " — see sift help answers (call sites)"
            lines = ["", header]
        }
        /// The count beside the list of the sites of `base` it does not list, narrowed by the labels of its declarations.
        func unlistedLines(of base: String) -> [String] {
            let owners = functionOwnersByBase[base] ?? []
            let scope = fileScope(of: rowsByBase[base] ?? [])
            let unlisted = (scanned[base] ?? []).filter { !$0.isListed(ownedBy: owners) && scope?.paths.contains($0.path) != false }
            let reaching = LabelNarrowed.reaching(unlisted, by: rowsByBase[base] ?? [])
            // Indented so the block still runs through it: a line at the margin would end it for a reader.
            return nameOnlyLines(reaching, cap: callSiteCap, initializerOf: scannedAs[base], narrowed: true, grouped: true, paging: paging).map { "  " + $0 }
        }
        for base in askedByBase.keys.sorted() {
            let owners = names.owners(askedByBase[base] ?? [])
            let byName = found[base] ?? []
            let labelled = kept[base]?.sites ?? byName
            // A call written on another type, or implicitly inside types that are none of those, is that type's own.
            // So is a leading-dot `.m(x)` nothing follows, where every declaration of the name is an instance member.
            let instanceOnly = try isInstanceOnly(base)
            let reaches = try reaching(base).map { reach in
                try labelled.map { try ($0, reach($0)) }.filter { $0.1.isKept && !(instanceOnly && $0.0.isUnchainedImplicitMemberCall) }
            }
            let received = reaches.map { $0.map(\.0) } ?? labelled
            let sites = instanceOnly ? received.filter { !$0.isUnchainedImplicitMemberCall } : received
            let word = shapes[base] == .use
                ? (absent: "use", one: "use", many: "uses")
                : (absent: "call", one: "call site", many: "call sites")
            let listed = sites.isEmpty ? "none" : String(sites.count)
            var counts = SameNamedTypes.dropped(another: 0, none: 0, named: scannedAs[base] ?? base)
            let dropped = counts.count
            if let qualified = qualifiedElsewhere[base], qualified > 0 {
                counts.append("\(qualified) written as an attribute behind a qualifier that spells no owner of it, kept: a typealias of the owner may make it this type's")
            }
            if let narrowed = kept[base], narrowed.droppedAnySite {
                counts.append("\(labelled.isEmpty ? "none" : String(labelled.count)) with the labels \(narrowed.labels)")
            }
            if labelled.count > sites.count {
                counts.append("\(labelled.count - sites.count)\(counts.isEmpty ? "" : " of them") on other types dropped, \(listed) kept")
            }
            if dropped > 0, counts.count == dropped {
                counts[dropped - 1] += ", \(listed) kept"
            }
            // A site kept only because its receiver could not be shown to be another type is counted, so the list never reads as proven callers.
            counts += ReceiverReach.keptClauses((reaches ?? []).map { (site: $0.0, reach: $0.1) })
            if !byName.isEmpty, let anyTypes = try MemberOperatorSites.clause(base: base, declarations: rowsByBase[base] ?? [], owner: owner(of:)) {
                counts.append(anyTypes)
            }
            // A private member is usable only in its own file, so a site anywhere else is another declaration's: the one narrowing the language makes sound, and said even where it dropped nothing.
            // Every declaration of the name counts, not only those asked of the store: one past that cap usable beyond its file keeps a site anywhere a use.
            let scope = fileScope(of: rowsByBase[base] ?? [])
            let inFile = scope.map { scope in sites.filter { scope.paths.contains($0.path) } } ?? sites
            if let scope {
                let elsewhere = sites.count - inFile.count
                counts.append("narrowed to its declaring file, as it is \(scope.level.rawValue)" + (elsewhere > 0 ? ": \(elsewhere) elsewhere dropped, \(inFile.count) kept" : ""))
            }
            // A site the store's answer for another declaration already lists is said once, there.
            let unlisted = inFile.filter { !listedAbove($0) }
            if unlisted.count < inFile.count {
                counts.append("\(inFile.count - unlisted.count) listed above")
            }
            // An initializer's site is listed only for one its written arguments reach; one reaching only others is
            // listed apart, under the ones it reaches, never only counted: no line above is its own, and a file written
            // since the build, a declaration past the store's cap, a caller's folded count or the cap on callers leaves
            // a live call nowhere else.
            let credit = scannedAs[base] == nil ? nil : InitializerCredit(rowsByBase[base] ?? [], asked: askedByBase[base] ?? [], named: names.name(of:))
            let shown = credit.map { credit in unlisted.filter { !credit.isAnotherInitializers($0) } } ?? unlisted
            // First, beside the count by name it qualifies: some of the calls just counted the index reads as another type's.
            counts.insert(contentsOf: readings[base]?.clauses(named: scannedAs[base] ?? base, listed: shown) ?? [], at: 0)
            let others = credit?.otherInitializersSites(among: unlisted) ?? []
            counts += others.map { "\($0.sites.count) whose labels reach only \($0.reaching)" }
            // Found by the struct's name rather than the property's, so counted apart from the uses by name above them.
            let labelCalls = try memberwise?.calls(passing: askedByBase[base] ?? [], among: sitesByName)
            let listsLabels = paging != nil || listsLabelCalls
            let labelClauses = labelCalls?.clauses(label: base, pointer: listsLabels ? nil : "--refs") ?? []
            let total = byName.count
            // They add to what the heading counts before them; with nothing before them they stand alone.
            counts += labelClauses.enumerated().map { $0.offset == 0 && (total > 0 || !counts.isEmpty) ? "plus " + $0.element : $0.element }
            let passed = listsLabels ? labelCalls?.listed ?? [] : []
            // One list, so a file's rows ascend by line whichever scan found each.
            let listing = passed.isEmpty ? shown : (shown + passed).sorted { ($0.path, $0.line) < ($1.path, $1.line) }
            func detail(_ site: SyntacticCallSite) -> String {
                "in \(site.enclosing)\(site.projection?.flag ?? "")\(kept[base]?.suffix(for: site) ?? "")\(credit?.suffix(for: site) ?? "")"
                    + (ambiguity[base]?.first { $0.site == site }?.flag ?? "") + (labelCalls?.flag(of: site) ?? "")
            }
            // Indented under the block, as the implicit calls counted beside it are, so the block runs through it.
            let reachingOthers = others.flatMap { group in
                let listed = paging.map { $0.rows(of: group.sites, detail: detail) }
                    ?? NameMatchedSites.rows(group.sites.prefix(callSiteCap), detail: detail)
                    + (group.sites.count > callSiteCap ? ["    truncated: \(group.sites.count - callSiteCap) more \(word.many)"] : [])
                return ["  reaching only \(group.reaching) by their labels, with no line of their own above:"] + listed.map { "  " + $0 }
            }
            let uses = total == 0 ? "no \(word.absent) by name" : "\(total) \(total == 1 ? word.one : word.many) by name"
            let counted = counts.isEmpty ? nil : "\(uses), " + counts.joined(separator: ", ")
            guard !listing.isEmpty else {
                lines.append("")
                let forOwners = owners.map { " (for \($0))" } ?? ""
                // A call writing the label was found and counted, not listed, so no verdict of absence or completeness holds.
                if let counted, !labelClauses.isEmpty {
                    lines.append("nothing spelled \"\(base)\" is listed here — \(counted)\(forOwners)")
                } else if let counted, scope != nil, inFile.isEmpty, !sites.isEmpty {
                    lines.append("no \(word.absent) spelled \"\(base)\" in its declaring file — \(counted)\(forOwners)")
                } else if let counted, !inFile.isEmpty {
                    let elsewhere = unlisted.count == inFile.count ? "reaches only another initializer by its labels"
                        : unlisted.isEmpty ? "is listed above" : "is listed above or reaches only another initializer by its labels"
                    lines.append("every \(word.absent) spelled \"\(base)\" \(elsewhere) — \(counted)\(forOwners)")
                } else if total == 0, !counts.isEmpty {
                    // Nothing spelled the name at all: what is counted is only how the scan was narrowed.
                    lines.append("no \(word.absent) spelled \"\(base)\" anywhere in the working tree — \(counts.joined(separator: ", "))\(forOwners)")
                } else if let counted, byName.isEmpty {
                    lines.append("no call spelled \"\(base)\" builds its type — \(counted)\(forOwners)")
                } else if let counted {
                    lines.append(labelled.isEmpty
                        ? "no call spelled \"\(base)\" with its labels anywhere in the working tree — \(counted)\(forOwners)"
                        : "every call spelled \"\(base)\"\(labelled.count < byName.count ? " with its labels" : "") is on another type — \(counted)\(forOwners)")
                } else {
                    lines.append("no \(word.absent) spelled \"\(base)\" anywhere in the working tree\(forOwners)")
                }
                lines += reachingOthers
                lines += unlistedLines(of: base)
                continue
            }
            let fileCount = Set(listing.map(\.path)).count
            let files = "\(fileCount) file\(fileCount == 1 ? "" : "s")"
            let forOwners = owners.map { " — for \($0)" } ?? ""
            lines.append("")
            if let counted {
                lines.append("\"\(base)\" (\(counted), in \(files)\(forOwners)):")
            } else {
                lines.append("\"\(base)\" (\(listing.count) \(listing.count == 1 ? word.one : word.many) in \(files)\(forOwners)):")
            }
            if let paging {
                lines += paging.rows(of: listing, detail: detail)
            } else {
                lines += NameMatchedSites.rows(listing.prefix(callSiteCap), detail: detail)
                if listing.count > callSiteCap {
                    // Label calls are listed in the same run as the uses and may be among the hidden ones, so they are not called uses.
                    lines.append("    truncated: \(listing.count - callSiteCap) more \(passed.isEmpty ? word.many : "\(word.many) or calls passing the label")")
                }
            }
            lines += reachingOthers
            // An initializer's `.init call` of a type the scan cannot tell is counted beside a list too, where a
            // function's bare name is not: the one may be a call the list misses, the other is mostly a same-named read.
            if scannedAs[base] != nil {
                lines += unlistedLines(of: base)
            }
        }
        for owner in unnameable.map(names.name(of:)).sorted() {
            lines.append("")
            lines.append("no name to match for \(owner): a subscript is used as x[…], which spells no name, so its reads and writes come from the index store alone")
        }
        return lines
    }

    /// The places a function with no listed site is still written by name with no call, so "no call" is never read as "unused" where one may be handed on unapplied.
    ///
    /// Counted beside the list rather than in it: `f`, `x.f` and another type's `T.f` are spelled exactly as a same-named local, property or case is read, which over a common name would bury the calls in unrelated reads. One row per line, as the name written twice on one — `self.size = size` — is one place to look.
    ///
    /// For the initializers of the type passed as `type`, they are its `.init call` calls and the `Self` calls in extensions whose type the scan cannot tell, which may be any type's; `narrowed` says they were narrowed by its initializers' labels, as `where` narrows them and `diff` does not. `grouped` lists each file's path once with its rows under it, as `where` lists every name-matched site; `diff` keeps a path on each row. `paging`, given with `grouped`, pages them by file in place of `cap`, as a no-store sweep pages every list.
    static func nameOnlyLines(
        _ written: [SyntacticCallSite],
        cap: Int,
        truncationPointer: String? = nil,
        initializerOf type: String? = nil,
        narrowed: Bool = false,
        grouped: Bool = false,
        paging: SyntacticSweepPaging? = nil
    ) -> [String] {
        var seen: Set<String> = []
        let sites = written.filter { seen.insert("\($0.path):\($0.line)").inserted }
        guard !sites.isEmpty else { return [] }
        let count = sites.count == 1 ? "once" : "\(sites.count) times"
        let labels = narrowed ? " with those labels" : ""
        // A `Self(x)` in an extension of a type declared elsewhere is said apart from an implicit `.init call`: neither spells the type.
        let onSelf = sites.contains(where: \.callsUntoldSelf)
        let made = !onSelf ? "an implicit .init" : sites.allSatisfy(\.callsUntoldSelf) ? "Self(…) in an extension" : "an implicit .init or Self(…) in an extension"
        var lines = [type.map { "but \(made) is called \(count)\(labels) on a type the scan cannot tell, any of which may be \($0)'s; verify before deleting:" }
            ?? "but the name is written \(count) with no call — a function handed on unapplied as f, x.f or T.f, or a same-named property, case or local; verify before deleting:"]
        if grouped, let paging {
            return lines + paging.rows(of: sites) { "in \($0.enclosing)" }
        }
        if grouped {
            lines += NameMatchedSites.rows(sites.prefix(cap)) { "in \($0.enclosing)" }
        } else {
            for site in sites.prefix(cap) {
                lines.append("  \(site.path):\(site.line)  in \(site.enclosing)")
            }
        }
        if sites.count > cap {
            let pointer = truncationPointer.map { " — \($0)" } ?? ""
            let indent = grouped ? "    " : "  "
            lines.append("\(indent)truncated: \(sites.count - cap) more\(pointer)")
        }
        return lines
    }
}

extension SyntacticCallerFallback {
    /// The files every site of `rows` must sit in, and the widest of their access levels, where each is `private` or `fileprivate`; `nil` where any is usable beyond its file.
    static func fileScope(of rows: [SymbolRow]) -> (paths: Set<String>, level: AccessLevel)? {
        guard let level = rows.map(\.accessLevel).max(), level <= .fileprivateLevel else { return nil }
        return (Set(rows.map(\.path)), level)
    }

    /// Whether an attribute site spells the type at the module-qualified `path`: one written bare does, and a qualified `@M.T` does where `M` is the declaring module or a type `T` is nested in. A site that does not is only noted, never dropped: Swift reads `@Wrap.State` through a typealias of the owner as `Outer.State`.
    static func attribute(_ site: SyntacticCallSite, mayNamePath path: String) -> Bool {
        guard let qualifier = site.qualifier else { return true }
        return ("." + path).hasSuffix("." + qualifier + "." + DeclaredTypeName.last(ofPath: path))
    }

    /// A name's call sites narrowed to the ones whose written labels could reach one of its declarations, when that dropped any.
    struct LabelNarrowed {
        let sites: [SyntacticCallSite]
        /// The labels the list was narrowed by, each overload's once — `(in:limit:) or ()`.
        let labels: String
        /// Whether any site of this name was actually dropped — the heading's "labels narrowed" is said only then, never for a site flagged but kept.
        let droppedAnySite: Bool
        /// Why a kept site's labels did not themselves reach a declaration, kept beside the site itself — never its `path:line`, which two sites on one line share — so the printed row can say so instead of the heading.
        private let keptWithoutMatch: [(site: SyntacticCallSite, flag: String)]
        private static var mayBeUnappliedOnSelf: String {
            " (may be unapplied on Self)"
        }

        private static var noDeclaredInitMatches: String {
            " (no declared init matches — compiler-written or inherited)"
        }

        /// `nil` unless every declaration is a function, or every one an initializer of one type, whose labels can be read, and at least one site either could reach none of them or is flagged for a row of its own.
        ///
        /// A site with no written arguments — a use rather than a call, or a reference by a bare name — is never dropped, and a reference by a compound name, `T.f(x:)`, is kept only where it spells one declaration's labels exactly, and neither is any site of a name one of whose declarations is something else: a property called through a closure it holds, or a type called as its initializer, takes labels no function signature states. A site matching none of an initializer's declared labels stays listed unless the query itself named labels: it can only be a call of an initializer the compiler wrote — a memberwise one, `init(rawValue:)`, a decoding `init(from:)` — or one inherited from a superclass, since a call matching no initializer at all would not compile; label narrowing only chooses between declared initializers otherwise. When the query does name labels, only sites matching those labels are kept, as a function's are.
        ///
        /// A call `Self.run(x)` is kept whatever its labels wherever it is written inside a type declared as one of `owners`, the types declaring the name, generic arguments and sugar set aside: there `x` may be the instance an unapplied method runs on.
        init?(_ sites: [SyntacticCallSite], by rows: [SymbolRow], ownedBy owners: Set<String>, initializerLabelsWereNamed: Bool = false) {
            guard let declared = Self.declared(rows) else { return nil }
            let isInitializer = rows.allSatisfy { $0.kind == .initializer }
            var keptWithoutMatch: [(site: SyntacticCallSite, flag: String)] = []
            let kept = sites.filter { site in
                guard let arguments = site.arguments else { return true }
                if arguments.application == .mayBeUnappliedOnSelf,
                   site.enclosingTypes.contains(where: owners.contains)
                {
                    keptWithoutMatch.append((site, Self.mayBeUnappliedOnSelf))
                    return true
                }
                if declared.contains(where: { $0.accepts(arguments) }) {
                    return true
                }
                guard isInitializer, !initializerLabelsWereNamed else { return false }
                keptWithoutMatch.append((site, Self.noDeclaredInitMatches))
                return true
            }
            let droppedAnySite = kept.count < sites.count
            guard droppedAnySite || !keptWithoutMatch.isEmpty else { return nil }
            self.sites = kept
            self.droppedAnySite = droppedAnySite
            self.keptWithoutMatch = keptWithoutMatch
            var seen: Set<String> = []
            labels = declared.map(\.spelled).filter { seen.insert($0).inserted }.joined(separator: " or ")
        }

        /// The flag to print after a kept site's row, or `""` where nothing about it was flagged.
        func suffix(for site: SyntacticCallSite) -> String {
            keptWithoutMatch.first { $0.site == site }?.flag ?? ""
        }

        /// The sites whose written labels could reach one of `rows`, or all of them where the rows cannot narrow.
        static func reaching(_ sites: [SyntacticCallSite], by rows: [SymbolRow]) -> [SyntacticCallSite] {
            guard let declared = declared(rows) else { return sites }
            return sites.filter { site in site.arguments.map { arguments in declared.contains { $0.accepts(arguments) } } ?? true }
        }

        /// The labels of every row, or `nil` unless all are functions, or all initializers, whose labels can be read.
        private static func declared(_ rows: [SymbolRow]) -> [ParameterLabels]? {
            guard !rows.isEmpty, rows.allSatisfy({ $0.kind == .function }) || rows.allSatisfy({ $0.kind == .initializer }) else { return nil }
            var declared: [ParameterLabels] = []
            for row in rows {
                guard let labels = ParameterLabels(signature: row.signature, name: row.name) else { return nil }
                declared.append(labels)
            }
            return declared
        }
    }
}
