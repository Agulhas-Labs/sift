//
// Copyright © Agulhas Labs
//

import Foundation

/// Renders type, file, and module digests — declarations only, deterministic bytes, budgeted output.
///
/// The one exception to "declarations only" is a *qualified member* target (`Type.member`), which returns that member's source: the line range is already indexed, so serving the body directly collapses the tool's core loop — digest for shape, then a ranged Read for the one member that matters — into a single call when the caller already knows the member's name.
public struct DigestRenderer {
    let store: IndexStore
    let moduleNames: [String]
    let repoRoot: URL
    /// Supplies the other registered roots whose existing index accounts for the *whole* target — appended to miss answers as a pointer, so a sibling repo's type stops dead-ending (see `SiblingIndexProbe`).
    var siblingRoots: ((String) -> [SiblingPointer])?
    /// The narrowing the index was built under — consulted only when a file target misses, to name the rule that kept an existing file out.
    var config = SiftConfig()
    /// Every read of the source this digest serves goes through here; the engine hands in one that checks the bytes against their rows.
    var sourceReader = ServedSourceReader()
    /// Where a relative path target is read from when the repository root's own reading of it names no indexed file.
    var currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    /// Member lines per page; enum case packs and headings don't count (Docs/Design.md §3).
    static var memberCap: Int {
        60
    }

    /// Source lines served for a member body before truncating — a guard against a 500-line function undoing the saving the tool exists for.
    static var bodyLineCap: Int {
        200
    }

    /// View-outline lines a single digest may carry, across every member in it.
    ///
    /// `paginate` budgets one *member* line per member, so without this a type with a dozen `some View` methods could render twelve forty-line outlines and never trip the page cap — a digest larger than the file it summarises, which is the failure the tool exists to prevent. The per-member limit in `ViewOutline` bounds one member; this bounds the answer.
    static var outlineCap: Int {
        120
    }

    func render(target: String, options: DigestOptions) throws -> String {
        try measured(target: target, options: options).text
    }

    /// The same answer, carrying what it measured itself against where both sides were counted.
    ///
    /// Only the two shapes that weigh a digest against real source — a type and a file — can report anything; a module listing, a repo overview and every miss answer stand in for nothing measurable and say so by carrying no bytes.
    func measured(target: String, options: DigestOptions) throws -> MeasuredAnswer {
        if target == "." {
            return try MeasuredAnswer(text: renderRepoOverview())
        }
        if let range = DigestLineRange.parse(target) {
            return try renderFileRange(range, options: options)
        }
        // Before the file path below, because a Markdown file is answered from disk rather than from the
        // index — and because `Notes.md` carries no `/` and would otherwise be read as a qualified type
        // name. A path this cannot read gets the Markdown miss, which names the exact-path rule.
        if MarkdownOutline.names(target) {
            return renderMarkdown(path: target, options: options) ?? MeasuredAnswer(text: markdownMiss(path: target), missed: true)
        }
        if target.contains("/") || target.hasSuffix(".swift") {
            return try renderFile(path: target, options: options)
        }
        // A name written in backticks is asked for by the name the index holds, which drops them around an ordinary word.
        let target = SymbolNaming.unbackticked(target)
        if moduleNames.contains(target) {
            return try MeasuredAnswer(text: renderModule(target, options: options))
        }
        if target.contains(".") {
            let components = QualifiedPath.components(of: target)
            if components.count >= 2, moduleNames.contains(components[0]) {
                return try renderType(
                    name: components[components.count - 1],
                    qualifiers: Array(components[1 ..< components.count - 1]),
                    module: components[0],
                    memberTarget: target,
                    options: options
                )
            }
            return try renderType(
                name: components[components.count - 1],
                qualifiers: Array(components[0 ..< components.count - 1]),
                module: nil,
                memberTarget: target,
                options: options
            )
        }
        return try renderType(name: target, qualifiers: [], module: nil, memberTarget: nil, options: options)
    }

    // MARK: Repo overview

    /// The whole-repository view a cold session starts from: every module with its size, one screen.
    ///
    /// This is the digest that completes the design's case against generated architecture files (Docs/Design.md §1): the derivable overview those files carry is served here on demand, under the freshness header, instead of rotting in prose. It is also the only module *discovery* the MCP face has — `status` is CLI-only, so without this an agent would have to know a module's name to ask about it.
    private func renderRepoOverview() throws -> String {
        let overview = try store.moduleOverview()
        let files = overview.reduce(0) { $0 + $1.files }
        let symbols = overview.reduce(0) { $0 + $1.topLevelSymbols }
        // The one answer here that is nothing *but* totals, and so the one where the count notice is the
        // whole of what a reader can be told. Repo-wide because the subject is the repository: every file
        // the parser could not finish is a file one of these numbers was counted from.
        var lines = try countBanner(ParseErrorNotice.acrossRepository(store))
        lines.append("repo — \(overview.count) module\(overview.count == 1 ? "" : "s"), \(files) files, \(symbols) top-level declarations")
        let hasConfig = FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent(".sift.json").path)
        lines.append("config: \(hasConfig ? ".sift.json" : "none (defaults)")")
        lines.append("")
        lines.append("modules:")
        for row in overview {
            lines.append("  \(row.module) — \(row.files) file\(row.files == 1 ? "" : "s"), \(row.topLevelSymbols) top-level declaration\(row.topLevelSymbols == 1 ? "" : "s")")
        }
        lines.append("")
        lines.append("digest <Module> lists one module's declarations; digest <Type> serves a type's shape")
        return lines.joined(separator: "\n")
    }

    // MARK: Type digest

    private func renderType(name: String, qualifiers: [String], module: String?, memberTarget: String?, options: DigestOptions) throws -> MeasuredAnswer {
        var declarations = try store.typeDeclarations(named: name, inModule: module)
        if !qualifiers.isEmpty {
            declarations = try declarations.filter { row in
                let chainNames = try enclosingNames(of: row)
                return chainNames.suffix(qualifiers.count) == qualifiers[...]
            }
        }

        if declarations.isEmpty {
            // A qualified target naming no type is the `Type.member` case — resolve it as a member and serve its body, rather than answering a member query with the "nearest symbols" list.
            if let memberTarget, let body = try renderMemberBody(target: memberTarget, options: options) {
                // A member's source has no digest it stands in for — the alternative is a ranged Read of the
                // same lines, which is the same bytes. Nothing to measure, so nothing is claimed.
                return MeasuredAnswer(text: body)
            }
            return try DigestMissAnswer(renderer: self).renderExternalTypeOrCandidates(name: name, qualifiers: qualifiers, module: module, wasMemberTarget: memberTarget != nil, options: options)
        }
        if declarations.count > 1 {
            // `typeDeclarations(named:)` reads the whole index, so this count is evidenced repo-wide while the
            // answer cites only the files it found — and a declaration lost to a truncated file is missing from
            // both. A shorter list of candidates is invisible: a reader looking at three has no way to know it
            // should have said four, which is the same reasoning the absence banner rests on.
            //
            // The listing form rather than the counted note, because this answer carries no other banner to
            // restate: nothing here draws on a file's *contents*, only on names and ranges already resolved, so
            // the paths stand alone — and they are the one thing a reader choosing between candidates can act
            // on, since a broken file is where the candidate they meant may be hiding.
            //
            // The *absence* wording of the two, because these paths are not files the candidates came from —
            // they are where the missing candidate would have been. Beside a list of candidates the other
            // wording reads as "and here is where these came from", which sends a reader to open files that
            // have nothing to do with the question.
            var lines = try absenceCountBanner(ParseErrorNotice.acrossRepository(store))
            lines.append("\(name) is ambiguous — \(declarations.count) declarations; digest one of these exact targets:")
            for (row, target) in try zip(declarations, DigestExactTargets(renderer: self).of(declarations)) {
                lines.append("  digest \(target) — \(row.kind.rawValue) — \(row.path)\(row.rangeDescription)")
            }
            return MeasuredAnswer(text: lines.joined(separator: "\n"))
        }

        let primary = declarations[0]
        let extensions = try store.extensions(ofTypeNamed: name).filter { try owns(extension: $0, primary: primary) }
        let paths = [primary.path] + extensions.map(\.path)
        // Two exposures, not one, and only the first is answer-scoped. The cited files can be truncated,
        // which the banner covers. The extension *count* cannot be scoped at all: `extensions(ofTypeNamed:)`
        // is a repository-wide query because an extension may be declared in any file, so a file truncated
        // before its extension was read contributes no row — and therefore is not among the cited paths
        // either. The banner goes silent about precisely the file that could have changed the number.
        //
        // In the preamble rather than beside the header, because `SourcePassthrough` reprints the header
        // and its `(+N extensions)` over the served source; a note appended after the header here would be
        // dropped from exactly the answers that are cheap enough to pass through.
        let preamble = try parseErrorBanner(touching: paths)
            + extensionCountNote()
            + guessedModuleBanner(touching: paths)
        var lines = preamble
        let extensionNote = extensions.isEmpty ? "" : " (+\(extensions.count) extension\(extensions.count == 1 ? "" : "s"))"
        let header = "\(name) — \(primary.module) — \(primary.path)\(primary.rangeDescription)\(extensionNote)"
        lines.append(header)
        lines.append(decorated(signature: SourceSlicer.shown(primary.signature), options: options) + macroMarker(for: primary))

        let children = try store.children(of: primary.id)

        var enumCaseCount = 0
        if primary.kind == .enumKind {
            let cases = children.filter { $0.kind == .enumCase }
            if !cases.isEmpty {
                enumCaseCount = cases.count
                lines.append("")
                lines.append("cases (\(cases.count)): " + cases.map(\.name).joined(separator: " "))
            }
        }

        var budgeted: [BudgetedLine] = []
        var outlineBudget = Self.outlineCap
        // A suite named as a type takes what its file digest takes, over the members of every one of its
        // extensions too — naming the suite is the natural call, and its helpers are often declared apart.
        let suites = try store.fileRow(path: primary.path).flatMap {
            SuiteAnnotation(file: $0, store: store, repoRoot: repoRoot, options: options)
        }
        let suite = try suites?.suite(owning: primary)
        /// Eligibility is decided now, over every member whatever page ends up served — a test has to be recorded as its suite's latest regardless of pagination.
        ///
        /// The source itself is inlined later, only for the members a page actually keeps (`inlined(_:suites:indent:)`), so an eligible member here carries only the row a later page might inline, never the inlined text.
        func eligibleHelper(_ member: SymbolRow) throws -> SymbolRow? {
            guard let suites, let suite else { return nil }
            return try suites.classify(member, suite: suite) ? member : nil
        }
        let stored = children.filter { $0.kind == .variable && $0.isStored }
        if !stored.isEmpty {
            budgeted.append(BudgetedLine(text: "stored properties:", counted: false))
            for row in stored {
                budgeted.append(BudgetedLine(text: memberLine(row, options: options, outlineBudget: &outlineBudget), counted: true))
            }
        }
        let others = children.filter { !($0.kind == .variable && $0.isStored) && $0.kind != .enumCase }
        if !others.isEmpty {
            if !stored.isEmpty {
                budgeted.append(BudgetedLine(text: "", counted: false))
            }
            budgeted.append(BudgetedLine(text: "members:", counted: false))
            for row in others {
                try budgeted.append(BudgetedLine(
                    text: containerAwareLine(row, options: options, outlineBudget: &outlineBudget),
                    counted: true,
                    helper: eligibleHelper(row)
                ))
            }
        }
        for extensionRow in extensions {
            budgeted.append(BudgetedLine(text: "", counted: false))
            budgeted.append(BudgetedLine(
                text: "extension \(extensionRow.name)\(extensionContext(extensionRow)) — \(extensionRow.path)\(extensionRow.rangeDescription)",
                counted: false
            ))
            for member in try store.children(of: extensionRow.id) {
                try budgeted.append(BudgetedLine(
                    text: containerAwareLine(member, options: options, outlineBudget: &outlineBudget),
                    counted: true,
                    helper: eligibleHelper(member)
                ))
            }
        }

        lines.append("")
        let page = inlined(paginate(budgeted, options: options, unit: "member lines"), suites: suites, indent: "  ")
        lines.append(contentsOf: page + DigestSignatureLayout.cutNote(over: page))
        lines.append(contentsOf: suites?.closingLines ?? [])
        lines.append("")
        lines.append(synthesizedNote(for: primary))
        let digest = lines.joined(separator: "\n")

        // Both options narrow what the caller wants to see, so serving the whole source would answer a
        // question they did not ask: `offset` is a cursor into a digest that must stay a digest to be
        // paged, and `signaturesOnly` is a request for *less* than the default.
        guard options.offset == 0, !options.signaturesOnly else {
            return MeasuredAnswer(text: digest)
        }
        return SourcePassthrough.decide(
            insteadOf: digest,
            header: header,
            // Enum cases are named on their own line above the budget rather than inside it, so counting the
            // budget alone would call a twenty-case enum with one method a two-declaration digest — the one
            // shape the degenerate floor must not fire on, since listing the cases *is* the answer.
            named: enumCaseCount + budgeted.filter(\.counted).count,
            sites: [primary] + extensions,
            read: { sourceReader.text(of: $0, under: repoRoot) },
            preamble: preamble
        ).answer(keeping: digest)
    }

    /// Not `private`: `DigestMissAnswer` cites a symbol the same way.
    func qualifiedTarget(of row: SymbolRow) throws -> String {
        try store.qualifiedName(of: row)
    }

    /// The names enclosing a symbol, outermost first, one element per written component.
    ///
    /// Flattened deliberately: an extension row's name is the *written* extended type, so `extension A.B` is one chain element spelling two. Compared unflattened, a type declared inside it would have the chain `["A.B", "C"]`, which no three-part qualifier could ever match — `digest A.B.C` would dead-end on "no type or member named C" while the nearest-symbols list underneath printed the very declaration it had just refused.
    func enclosingNames(of row: SymbolRow) throws -> [String] {
        try QualifiedPath.flattened(chain: store.parentChain(of: row).map(\.name))
    }

    /// Whether an extension extends *this* declaration rather than a same-named type elsewhere.
    ///
    /// `extensions(ofTypeNamed:)` matches the bare name, which is right for a top-level type and wrong for a nested one: a set of lint rules each declaring their own `Visitor` would have every other rule's extension members grafted onto every answer. Swift is what makes the test exact — an extension sits at file scope, so a nested type can only be extended by its full path, and a bare `extension Visitor` therefore always means the top-level one.
    ///
    /// Not `private`: `DigestMissAnswer` separates a local extension from an external type's the same way.
    func owns(extension row: SymbolRow, primary: SymbolRow) throws -> Bool {
        let written = row.name.split(separator: ".").map(String.init)
        let chain = try enclosingNames(of: primary) + [primary.name]
        if written == chain {
            return true
        }
        // Only a *module* qualifier may be dropped, and only this declaration's own. Dropping any leading component that merely happens to name a module would amputate the enclosing type wherever a module and a top-level type share a name — the SwiftPM norm `renderModule` already notes below — losing the nested type's whole extension with the header count agreeing it had none. Requiring the module to be `primary`'s also stops a foreign module's qualifier being discarded and then matched, which is the disambiguation the caller wrote it for.
        guard let first = written.first, first == primary.module else { return false }
        return Array(written.dropFirst()) == chain
    }

    // MARK: Member body

    /// The current source of a qualified member target (`Type.member`, `Module.Type.member`, or a labeled form like `save(_:to:)`), or `nil` when the target names no member and the type paths should answer instead.
    ///
    /// Source is read from disk at query time, never a stored snippet — sound because the syntactic axis self-heals, so the indexed range matches the file it is sliced from. Type kinds are excluded deliberately: a type's answer is its digest, and only the type path may serve it.
    func renderDeclaredMemberBody(target: String, options: DigestOptions) throws -> String? {
        // Every *container* kind is excluded, not just nominal types: an extension is not a member either, and serving its source would hijack `Module.ExternalType` away from the "declared outside this repo" answer — worse, two extensions would make it suggest the very query that produced the message, one target per extension, with no way out of the loop.
        let members = try WhereRenderer(store: store)
            .declarations(for: target)
            .filter { !$0.kind.isContainer }
        guard let first = members.first else {
            return try deinitSource(target: target)
        }
        if members.count > 1 {
            // The type-ambiguity answer's twin, and the same repo-wide count: `declarations(for:)` resolves
            // through `symbols(named:)`, so a member lost with the tail of a truncated file is missing from
            // this number and from the list under it, and the file that would have carried it is not among the
            // paths named here — because nothing in it was readable to name. A served answer words its own
            // repository-wide notice, which leaves out the files it served from.
            if options.offset == 0, let served = try SmallOverloadsServed(renderer: self).answer(members, target: target) {
                return served.joined(separator: "\n")
            }
            var lines = try absenceCountBanner(ParseErrorNotice.acrossRepository(store))
            lines.append("\(target) is ambiguous — \(members.count) declarations; digest one of these exact targets:")
            for (row, exact) in try zip(members, DigestExactTargets(renderer: self).of(members)) {
                let location = "\(row.path)\(row.rangeDescription)"
                // A file range is already the location, so the line says it once.
                lines.append("  digest \(exact) — \(row.kind.rawValue)" + (exact == location ? "" : " — \(location)"))
            }
            return lines.joined(separator: "\n")
        }
        return try memberSource(of: first, target: target, options: options)
    }

    /// The answer to a `Type.deinit`, which the index never stores and so no member lookup finds, or `nil` where the target names no type.
    private func deinitSource(target: String) throws -> String? {
        let lookup = try DeinitLookup(store: store) { [repoRoot] row in
            guard case let .lines(lines, _) = SourceSlicer.slice(of: row, under: repoRoot) else { return nil }
            return lines
        }.lookup(for: target)
        guard let lookup else { return nil }
        let preamble = try parseErrorBanner(touching: lookup.cited) + guessedModuleBanner(touching: lookup.cited)
        return DeinitLookup.digestAnswer(for: lookup, target: target, preamble: preamble, under: repoRoot)
    }

    /// A single member's source, capped at `bodyLineCap` and paged by `options.offset`, with the ranged Read that fetches any remainder.
    ///
    /// The resume target is the target that serves `row` alone, given for a block served beside others: there a bare "pass --offset" would be sent back with the target that produced several blocks, which refuses an offset, so the advice names the one call that pages this block — that target with the offset, spelled for the face — instead.
    private func memberSource(of row: SymbolRow, target: String, options: DigestOptions, resumeTarget: String? = nil) throws -> String {
        // A member body is served verbatim from the file, so a parse error in it can have truncated the very range being sliced — the banner leads here as it does on every other digest path.
        let preamble = try parseErrorBanner(touching: [row.path]) + guessedModuleBanner(touching: [row.path])
        let header = try SmallOverloadsServed(renderer: self).header(of: row)
        switch SourceSlicer.slice(of: row, in: sourceReader.text(of: row.path, under: repoRoot)) {
        case .unreadable:
            return (preamble + ["\(target) resolves to \(row.path), which could not be read"]).joined(separator: "\n")
        case .emptyRange:
            return (preamble + ["\(target) has an empty range at \(row.path)\(row.rangeDescription)"]).joined(separator: "\n")
        case let .lines(all, firstLineNumber):
            // `offset` is the same cursor the truncation markers elsewhere in this file teach, measured here in body lines rather than member lines.
            let offset = min(max(0, options.offset), all.count)
            var body = Array(all.dropFirst(offset).prefix(Self.bodyLineCap))
            if offset > 0 {
                body.insert("(…\(offset) body lines skipped)", at: 0)
            }
            let remaining = all.count - offset - min(Self.bodyLineCap, all.count - offset)
            if remaining > 0 {
                let resumeLine = firstLineNumber + offset + Self.bodyLineCap
                let resumeOffset = offset + Self.bodyLineCap
                let resume = resumeTarget.map { options.spelling.digest($0, offset: resumeOffset) } ?? "pass \(options.spelling.offset(resumeOffset))"
                body.append("… truncated: \(remaining) more lines — \(resume), or Read \(row.path) from line \(resumeLine)")
            }
            return (preamble + [header, ""] + body).joined(separator: "\n")
        }
    }

    // MARK: File digest

    private func renderFile(path: String, options: DigestOptions) throws -> MeasuredAnswer {
        // The index stores repo-relative paths only, so an absolute path into this checkout, or one spelled through
        // `.` or `..`, is resolved as the relative path it names — the same file, which would otherwise be refused as
        // absent.
        let file: FileRow
        let leadingNotice: [String]
        switch try resolveFile(path: relativeToRepository(path) ?? path) {
        case let .file(row):
            (file, leadingNotice) = (row, [])
        case let .ambiguous(candidates):
            return MeasuredAnswer(text: ambiguousFileAnswer(path: path, candidates: candidates))
        case .missing:
            switch try DigestFileBasenameFallback(renderer: self).missingFileResolution(path: path) {
            case let .resolved(row, notice):
                (file, leadingNotice) = (row, [notice])
            case let .answer(answer):
                return answer
            }
        }
        let preamble = try leadingNotice + parseErrorBanner(touching: [file.path]) + guessedModuleBanner(touching: [file.path])
        var lines = preamble
        let header = "\(file.path) — module: \(file.module)"
        lines.append(header)
        if !file.imports.isEmpty {
            lines.append("imports: " + file.imports.joined(separator: " "))
        }
        lines.append("")
        var outlineBudget = Self.outlineCap
        // `nil` for every ordinary file, which takes none of what a suite's digest adds.
        let suites = SuiteAnnotation(file: file, store: store, repoRoot: repoRoot, options: options)
        // No access filter on this path, unlike the module digest below. `private` is scoped to the file, so a
        // file's private declarations *are* the file — filtering them answers a different question than the one
        // asked, and answers it silently: a file digest would list a fraction of the members its own summary line
        // announces, and drop a private extension wholesale, with nothing to say either had happened. Whole-file
        // reads of a file already digested are what that costs.
        let topLevel = try store.topLevelSymbols(inFileID: file.id)
        let budgeted = try FileDigestMembers(renderer: self, topLevel: topLevel).budget(topLevel: topLevel, suites: suites, options: options, outlineBudget: &outlineBudget)
        let page = inlined(paginate(budgeted, options: options, unit: "member lines"), suites: suites, indent: "    ")
        lines.append(contentsOf: page + DigestSignatureLayout.cutNote(over: page))
        lines.append(contentsOf: suites?.closingLines ?? [])
        let digest = lines.joined(separator: "\n")

        guard options.offset == 0, !options.signaturesOnly else {
            return MeasuredAnswer(text: digest)
        }
        return SourcePassthrough.decide(
            insteadOf: digest,
            header: header,
            // A file digest enumerates every child of every top-level declaration, enum cases included, so
            // the budget already holds one line per declaration named.
            named: budgeted.filter(\.counted).count,
            filePath: file.path,
            read: { sourceReader.text(of: $0, under: repoRoot) },
            preamble: preamble
        ).answer(keeping: digest)
    }

    /// Exact path first, then a unique component-boundary suffix match ("Core/SummaryState.swift") — never a bare-suffix guess, which would hand back a *different* file's digest with confidence.
    ///
    /// A suffix several files end in is its own outcome rather than a miss: "no indexed file matches" is false about a target that matched more than one, and the matches are exactly what the caller needs to choose from.
    func resolveFile(path: String) throws -> FileResolution {
        if let exact = try store.fileRow(path: path) {
            return .file(exact)
        }
        let inventory = try store.fileInventory()
        let matches = inventory.keys.filter { $0.hasSuffix("/" + path) }.sorted()
        return switch matches.count {
        case 0:
            .missing
        case 1:
            inventory[matches[0]].map(FileResolution.file) ?? .missing
        default:
            .ambiguous(matches)
        }
    }

    /// The candidates for a suffix several indexed files end in, each as the exact target that digests it, cut to the page cap with the cut stated — a list that stops without saying so reads as every file there is.
    ///
    /// `suffix` is the line range the target asked for, carried onto every suggestion: the call it suggests has to ask for the same lines, or following it answers a different question.
    private func ambiguousFileAnswer(path: String, candidates: [String], suffix: String = "") -> String {
        var lines = ["\(path) is ambiguous — \(candidates.count) indexed files end in it; digest one of these exact targets:"]
        lines += candidates.prefix(Self.memberCap).map { "  digest \($0)\(suffix)" }
        if candidates.count > Self.memberCap {
            lines.append("  truncated: \(candidates.count - Self.memberCap) more files")
        }
        return lines.joined(separator: "\n")
    }

    /// What a file target that resolves to no indexed file is answered with: the plain miss, unless the file exists in this repository and a rule of the index keeps it out — then that rule, and the one way left to see the file.
    ///
    /// The rule comes from the same ``FileEnumerator`` the index is built by, so the answer cannot name a reason other than the one that applied. Git's ignore rules are applied by the listing rather than by the enumerator, so they are asked of git — last, and only for a file no other rule accounts for, which keeps a process launch off every answer the rules already settle. A path that leaves the repository, or names a directory, keeps the plain miss: neither is a file this index could have held.
    ///
    /// `excluded` tells the caller which of the two this is: a plain miss named nothing at all, while an exclusion found exactly the file the target named and said why it isn't indexed — an answer about something that is there, not a miss, whatever else the target looked like (a spaced path included).
    func unindexedFileAnswer(path: String) -> (text: String, excluded: Bool) {
        let miss = "\(DigestMiss.noIndexedFilePrefix)\(path)"
        guard let relative = relativeToRepository(path), fileExistsOnDisk(relative) else { return (miss, false) }
        let exclusion = FileEnumerator(repoRoot: repoRoot, config: config).exclusion(of: relative)
            ?? (GitContext(repoRoot: repoRoot).ignores(relativePath: relative) ? .gitIgnored : nil)
        guard let exclusion else { return (miss, false) }
        return ("\(relative) exists but is not indexed — \(exclusion.reason). A plain Read is the way to see it: nothing in it is in the index.", true)
    }

    // MARK: Lines

    private func memberLine(
        _ row: SymbolRow,
        options: DigestOptions,
        indent: String = "  ",
        outlineBudget: inout Int
    ) -> String {
        let signature = signatureLines(of: row, options: options)
        var line = indent + signature[0] + "  " + row.rangeDescription
        if let condition = row.ifConfigCondition {
            line += "  [\(condition)]"
        }
        if !options.signaturesOnly, let doc = row.docSummary {
            line += "  /// " + doc
        }
        // The range stays on the first line, where every member line has it, and the parameters that did not
        // fit continue beneath — still one member line, so pagination counts the member once.
        line += signature.dropFirst().map { "\n" + indent + $0 }.joined()
        // A view's structure is the one body this digests, because for view code it *is* the declaration
        // surface — `var body: some View` on its own says nothing about the screen. Suppressed under
        // `--signatures-only`, which asks for exactly the signatures and nothing beneath them.
        if !options.signaturesOnly, let outline = row.viewOutline {
            // An exhausted budget is said out loud rather than simply dropping the outline. The partial case
            // prints its marker; printing nothing in the total one would make a view member read as having no
            // structure worth showing instead of one whose structure did not fit — and file digests reach the
            // budget often, since they carry private members too.
            if outlineBudget > 0 {
                var rows = outline.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                if rows.count > outlineBudget {
                    rows = Array(rows.prefix(max(0, outlineBudget - 1))) + ["… outline truncated"]
                }
                outlineBudget -= rows.count
                line += "\n" + rows.map { indent + "  " + $0 }.joined(separator: "\n")
            } else {
                line += "  [outline omitted — budget spent]"
            }
        }
        return line
    }

    private func passesAccessFilter(_ row: SymbolRow, options: DigestOptions) -> Bool {
        options.includeAllAccess || row.accessLevel >= .internalLevel
    }

    /// Pages the member lines by their own `counted` tags — never by re-sniffing rendered text, which misclassifies members whose doc summaries end in ':' and silently drops them between pages.
    ///
    /// Returns entries rather than text: a kept entry can still carry a suite helper's member (`BudgetedLine.helper`), and inlining that source — which is what the caller does next, only to what this returns — must see just the page actually served, never a member `offset` skipped past.
    ///
    /// Not `private`: `DigestMissAnswer`'s extension listing pages the same way.
    ///
    /// `unit` has no default, so every caller names what its own counted lines are — a default is how a module listing came to report its top-level declarations as "member lines".
    ///
    /// `unit` names what the markers count, because a cursor a reader is handed has to say what it steps over — a Markdown outline's entries are headings, and telling someone they skipped 60 member lines of a document they can see has none is how a correct number stops being believed.
    func paginate(_ budgeted: [BudgetedLine], options: DigestOptions, unit: String) -> [BudgetedLine] {
        let offset = max(0, options.offset)
        let contentIndices = budgeted.indices.filter { budgeted[$0].counted }
        guard contentIndices.count > options.pageSize || offset > 0 else {
            return budgeted
        }
        let window = contentIndices.dropFirst(offset).prefix(options.pageSize)
        guard let firstIndex = window.first else {
            return [BudgetedLine(text: "(offset \(offset) is past the end — \(contentIndices.count) \(unit) total)", counted: false)]
        }
        let lastIndex = window.last ?? firstIndex
        var page: [BudgetedLine]
        if offset > 0 {
            page = Array(budgeted[firstIndex ... lastIndex])
            page.insert(BudgetedLine(text: "(…\(offset) \(unit) skipped)", counted: false), at: 0)
        } else {
            page = Array(budgeted[budgeted.startIndex ... lastIndex])
        }
        let remaining = contentIndices.count - offset - window.count
        if remaining > 0 {
            page.append(BudgetedLine(text: "truncated: \(remaining) more \(unit) — pass \(options.spelling.offset(offset + window.count))", counted: false))
        }
        return page
    }

    /// A paginated page's lines, with any eligible helper's source inlined beneath its member now that only the members actually served are known.
    private func inlined(_ page: [BudgetedLine], suites: SuiteAnnotation?, indent: String) -> [String] {
        page.map { entry in
            guard let suites, let helper = entry.helper else { return entry.text }
            return suites.inline(entry.text, member: helper, indent: indent)
        }
    }
}

// MARK: - Markdown outline

/// A Markdown document's heading outline — the one digest shape that is not about Swift, and the one that reads its subject live rather than from the index.
private extension DigestRenderer {
    /// A Markdown document's heading outline, read live from disk at query time — the locating step for a ranged Read of a large doc, the same loop a Swift digest opens.
    ///
    /// Nothing about a `.md` file is in the index and nothing about it is written there, so the answer says it was read live: a reader has to know that these line ranges were taken from the working tree just now, not from a store that could be stale.
    ///
    /// **Exact path only.** A repo-relative path, or an absolute one under the root; no suffix matching over the disk, which for prose would walk the tree on every miss and could hand back a different document's outline with confidence.
    ///
    /// `nil` where the target is no Markdown file this repository holds — a path that leaves the root, a directory, a file that is not there, or bytes that are not UTF-8. Each of those is answered by `markdownMiss(path:)`, never by the Swift file path's miss.
    func renderMarkdown(path: String, options: DigestOptions) -> MeasuredAnswer? {
        guard let relative = relativeToRepository(path) else { return nil }
        let url = repoRoot.appendingPathComponent(relative)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }

        let lines = SourcePassthrough.lines(of: source)
        let bytes = lines.joined(separator: "\n").utf8.count
        let header = "\(relative) — \(lines.count) line\(lines.count == 1 ? "" : "s"), \(ByteSize.short(bytes)) — read live from disk — headings only, nothing in it is indexed"
        let sections = MarkdownOutline.sections(of: lines)

        var body = [header, ""]
        if sections.isEmpty {
            // Said outright rather than left as an empty list: a heading outline that renders nothing reads
            // as a failure to parse the document, when what it means is that there is nothing to locate by.
            body.append("no headings — a plain Read is the way to see this one")
        } else {
            let shallowest = sections.map(\.level).min() ?? 1
            var bulletsBySection: [Int: [MarkdownOutline.Bullet]] = [:]
            for bullet in MarkdownOutline.bullets(of: lines) {
                bulletsBySection[bullet.section, default: []].append(bullet)
            }
            // A section's own bullets are woven in right after its heading line — the same document order the
            // headings already come in, since every bullet sits between its heading and the next one of any level.
            let budgeted = sections.flatMap { section -> [BudgetedLine] in
                var rows = [BudgetedLine(text: outlineLine(section, shallowest: shallowest, lines: lines), counted: true)]
                for bullet in bulletsBySection[section.start] ?? [] {
                    rows.append(BudgetedLine(text: bulletLine(bullet, shallowest: shallowest, section: section), counted: true))
                }
                return rows
            }
            body += paginate(budgeted, options: options, unit: "outline lines").map(\.text)
        }
        let outline = body.joined(separator: "\n")

        // As for a type or a file: a cursor pages an outline that must stay one, and `signaturesOnly` asks
        // for less than the default, so neither is answered with the whole document.
        guard options.offset == 0, !options.signaturesOnly else {
            return MeasuredAnswer(text: outline)
        }
        // The same floor every digest is weighed against: below the crossover an outline that would summarise
        // little is replaced by the document itself, with the arithmetic that decided it. A table of contents
        // for a page and a half is the shape that most deserves the check.
        return SourcePassthrough.decide(
            insteadOf: outline,
            header: header,
            named: sections.count,
            filePath: relative,
            read: { sourceReader.text(of: $0, under: repoRoot) },
            preamble: [],
            subject: .markdown
        ).answer(keeping: outline)
    }

    /// The miss for a `.md` target no document answers — named for what a Markdown target is, since "no indexed file" is true of every Markdown file, the ones that answer included.
    ///
    /// A readable document outside the root is the one miss whose first clause would otherwise state the opposite of the truth — the file *is* at that path, and a reader told there is none goes looking for the path rather than for the root, which costs a `find` that returns the path just rejected. So that case names the real reason and the flag that answers it; every other miss — a directory, a file that is not there, bytes that are not UTF-8 — keeps the exact-path rule, which is what a reader acts on there.
    func markdownMiss(path: String) -> String {
        documentOutsideRoot(path)
            ?? "no Markdown file at \(path) — a .md target is read live from disk by its exact path, repo-relative or absolute under the root"
    }

    /// The refusal for a document that is readable at `path` but sits outside this root, or `nil` where the target is not that case.
    ///
    /// The suggested root is the repository enclosing the file rather than its directory, because `--root` names a repository: pointing at a folder inside one would trade this refusal for git's.
    ///
    /// Both roots are spelled canonically. The line exists to be *compared* — this root against that one — and git spells a toplevel as the directory it was asked from, so a repository reached through a symlink would otherwise be named one way on the left and another on the right, which reads as two different places.
    ///
    /// A relative target is resolved against the root, as ``relativeToRepository(_:)`` resolves it, so the two cannot disagree about which file is being talked about. Read against the process's own directory instead, a relative target that leaves the root is probed at one path and named at another — "the file is there" said about a file nobody asked for, or the exemption missed entirely — and asking from a third directory is the ordinary case, since `--root` exists to be pointed elsewhere. The line names the resolved path for the same reason it spells both roots canonically: the reader is being handed places to compare. An absolute target is one spelled from `/`; it is named exactly as it was written, with no `~` expansion.
    private func documentOutsideRoot(_ path: String) -> String? {
        guard relativeToRepository(path) == nil else { return nil }
        let resolved = path.hasPrefix("/") ? path : URL(fileURLWithPath: repoRoot.appendingPathComponent(path).path).standardizedFileURL.path
        let url = URL(fileURLWithPath: resolved)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        let outside = "\(resolved) is outside this root (\(CanonicalPath.of(repoRoot.path))) — the file is there"
        guard let enclosing = GitContext.discoverRoot(from: url.deletingLastPathComponent()) else {
            return "\(outside), in no repository to root at — read it directly"
        }
        return "\(outside); re-run with --root \(CanonicalPath.of(enclosing.path))"
    }

    /// One heading, indented by its depth below the shallowest heading the document uses, with the range and the size of the section it opens.
    ///
    /// Indented against the shallowest *present* level rather than against `#`, so a document whose headings all start at `##` — every doc with its title in front matter — is not pushed a level in from the left for nothing.
    func outlineLine(_ section: MarkdownOutline.Section, shallowest: Int, lines: [String]) -> String {
        let indent = String(repeating: "  ", count: section.level - shallowest)
        let span = section.end - section.start + 1
        let bytes = lines[(section.start - 1) ... (section.end - 1)].joined(separator: "\n").utf8.count
        // A bare `###` is a heading with no text; an entry that is only a range would read as a rendering fault.
        let title = section.title.isEmpty ? "(untitled)" : section.title
        return "\(indent)\(title)  :\(section.start)-\(section.end)  (\(span) line\(span == 1 ? "" : "s"), \(ByteSize.short(bytes)))"
    }

    /// One top-level bullet under `section`, indented one level past its heading — the range leads, since a bullet row exists to be read *by*, not read *about*.
    ///
    /// A struck-through item carries a `[struck]` flag so a reader can tell it apart without reopening the range.
    func bulletLine(_ bullet: MarkdownOutline.Bullet, shallowest: Int, section: MarkdownOutline.Section) -> String {
        let indent = String(repeating: "  ", count: section.level - shallowest + 1)
        let flag = bullet.struck ? "  [struck]" : ""
        return "\(indent):\(bullet.start)-\(bullet.end)  \(bullet.title)\(flag)"
    }
}

// MARK: - Several targets

extension DigestRenderer {
    /// `path` in the repo-relative form the index stores, or `nil` when it leaves this repository; see `DigestPathResolution`.
    func relativeToRepository(_ path: String) -> String? {
        DigestPathResolution(renderer: self).relativeToRepository(path)
    }

    /// Whether `relative` (already resolved into the repo-relative form the index stores) names an ordinary file on disk — not a directory, and not nothing at all.
    ///
    /// Shared with ``DigestFileBasenameFallback``, which needs the same on-disk check to decide whether a plain miss is a candidate for its basename search: a path that already names a real file is never a wrong-directory guess.
    func fileExistsOnDisk(_ relative: String) -> Bool {
        var isDirectory: ObjCBool = false
        let onDisk = repoRoot.appendingPathComponent(relative).path
        return FileManager.default.fileExists(atPath: onDisk, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// Several targets answered as one — `digest Type.a Type.b Type.c` for the ranged-read-then-edit loop that would otherwise be one digest call locating them and N ranged reads fetching them.
    ///
    /// Each target renders exactly as it would alone, in the order given: every one already opens with a line naming what it answers (a qualified member, a type, a file, a module), so a blank line between them is the only separator an answer needs.
    func render(targets: [String], options: DigestOptions) throws -> String {
        try measured(targets: targets, options: options).text
    }

    /// A single target takes the plain path below and reports its own measurement unchanged; more than one reports none — a member's source already claims nothing (`renderMemberBody` below), and a mix of answer shapes has no one honest total to give in its place.
    ///
    /// An offset with several targets is refused rather than applied to each: it is a cursor into the one answer whose truncation line handed it out.
    func measured(targets: [String], options: DigestOptions) throws -> MeasuredAnswer {
        guard targets.count > 1 else {
            return try DigestSpacedTarget(renderer: self).measured(targets.first ?? "", options: options)
        }
        guard options.offset == 0 else {
            throw EngineError.offsetWithSeveralTargets(count: targets.count)
        }
        let bodies = try targets.map { try DigestSpacedTarget(renderer: self).measured($0, options: options).text }
        return MeasuredAnswer(text: Self.joinedAnswers(bodies))
    }

    /// The answer for lines between a large container's members: the container, and its nearest members on either side, each named as the target that serves it.
    ///
    /// The claim is worded to the lines actually inside `container`, not to the whole of `range`: a query that runs past either end of it intersects it only in part, and saying the full range "is in" it would claim lines the container never reaches (Docs/AnswerContract.md §8). Both ends are the walk's own: the container starts where `RangeWalk.start(of:)` says — at its doc comment, which is what brought these lines here — and ends at its closing brace.
    func betweenMembersAnswer(_ range: DigestLineRange, file: FileRow, container: SymbolRow, walk: RangeWalk) throws -> String {
        let members = (walk.children[container.id] ?? []).sorted { ($0.line, $0.id) < ($1.line, $1.id) }
        let before = members.last { $0.endLine < range.start }
        let after = members.first { walk.start(of: $0) > range.end }
        let containedStart = max(range.start, walk.start(of: container))
        let containedEnd = min(range.end, container.endLine)
        let spoken = containedStart == containedEnd ? "line \(containedStart)" : "lines \(containedStart)-\(containedEnd)"
        var lines = try parseErrorBanner(touching: [file.path])
        try lines.append("\(file.path) \(spoken) \(containedStart == containedEnd ? "is" : "are") in \(qualifiedTarget(of: container)) — \(container.kind.rawValue) — \(file.path)\(container.rangeDescription), but in none of its members; the nearest:")
        for (label, row) in [("before", before), ("after", after)] {
            guard let row else { continue }
            try lines.append("  \(label): digest \(qualifiedTarget(of: row)) — \(row.kind.rawValue) — \(row.path)\(row.rangeDescription)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - File digest by line range

/// `File.swift:12`, `File.swift:12-40`, or `File.swift:12:5` as a digest target — the shape a `where` answer or a stack trace hands back rather than a name.
///
/// **What the lines resolve to**, walking the file's declarations from the top:
/// - A declaration the lines cover whole is served as one block, its own header and the comments between its members included — so `:10-549` of a type is that type, not each of its members one by one.
/// - A declaration they only partly cover is served whole if it is a leaf within the source floor, and looked inside if it is a container. A longer leaf that holds every line asked for serves only those lines, under one header naming it and its whole range. A single line inside a leaf longer than `RangeInsideMemberAnswer.singleLineMemberCeiling` comes beneath the leaf's declaration with `RangeInsideMemberAnswer.lineWindowContext` lines either side and the range that reads the rest.
/// - A line in a declaration's doc comment belongs to that declaration, and its attributes already sit inside its range.
/// - Rows sharing one range — cases packed on one line — are one declaration's worth of source, served once, under the first of them.
/// - Lines inside a container that belong to none of its members — a blank line, a comment, the container's own header — are answered with the nearest members before and after, named with their ranges; the container itself is served only when it is small enough for the compression floor to have served it anyway.
/// - Lines no declaration reaches at all get the file's own digest and one line saying so.
private extension DigestRenderer {
    /// What a line range resolved to.
    enum RangeResolution {
        /// Declarations to serve, in order.
        case blocks([SymbolRow])
        /// Lines inside this container that none of its members reaches.
        case between(SymbolRow)
        /// Lines no declaration reaches.
        case outside
    }

    /// `File.swift:12-40` resolved and rendered — see the extension's own summary for what the lines resolve to.
    func renderFileRange(_ range: DigestLineRange, options: DigestOptions) throws -> MeasuredAnswer {
        let file: FileRow
        switch try resolveFile(path: relativeToRepository(range.path) ?? range.path) {
        case let .file(row):
            file = row
        case let .ambiguous(candidates):
            return MeasuredAnswer(text: ambiguousFileAnswer(path: range.path, candidates: candidates, suffix: range.suffix))
        case .missing:
            let resolution = unindexedFileAnswer(path: range.path)
            return MeasuredAnswer(text: resolution.text, missed: !resolution.excluded)
        }
        let rows = try store.symbols(inFile: file.path)
        let source = sourceReader.text(of: file.path, under: repoRoot)?.components(separatedBy: "\n") ?? []
        let children = Dictionary(grouping: rows.filter { $0.parentID != nil }) { $0.parentID ?? 0 }
        let walk = RangeWalk(span: range.start ... range.end, children: children, source: source)

        switch walk.resolve(among: rows.filter { $0.parentID == nil }) {
        case .outside:
            let digest = try renderFile(path: range.path, options: options)
            // The verdict leads (Docs/AnswerContract.md §2): a reader who stops at the first line already
            // knows nothing here spans the lines asked for, before ever reaching the file digest it fell back to.
            return MeasuredAnswer(text: "(no declaration spans \(range.spoken) in \(file.path))\n\n" + digest.text, bytes: digest.bytes)
        case let .between(container) where container.endLine - container.line + 1 <= SourcePassthrough.floorLineCeiling:
            return try MeasuredAnswer(text: memberSource(of: container, target: qualifiedTarget(of: container), options: options))
        case let .between(container):
            var answer = try betweenMembersAnswer(range, file: file, container: container, walk: walk)
            // A short list of neighbours is one page, so an offset has nothing here to skip. It is served anyway,
            // with the offset named as unused: unlike several blocks, one answer leaves no doubt what the offset
            // was meant to page, and dropping it in silence would read as having honoured it.
            if options.offset > 0 {
                answer += "\n(offset \(options.offset) unused — this answer is a single page)"
            }
            return MeasuredAnswer(text: answer)
        case let .blocks(blocks):
            if blocks.count == 1, let lines = try RangeInsideMemberAnswer(renderer: self).answer(blocks[0], range: range, walk: walk, source: source, options: options) {
                return MeasuredAnswer(text: lines)
            }
            guard blocks.count == 1 || options.offset == 0 else {
                throw EngineError.offsetAcrossSeveralDeclarations(target: range.path + range.suffix, count: blocks.count)
            }
            // Beside other blocks, a truncated one names its own exact range as the call that pages it: those
            // lines cover that declaration whole and nothing else, so they resolve to it alone, and an offset
            // on one block is honoured where the range that produced several refuses it.
            let bodies = try blocks.map { row in
                try memberSource(
                    of: row,
                    target: qualifiedTarget(of: row),
                    options: options,
                    resumeTarget: blocks.count > 1 ? "\(file.path):\(row.line)-\(row.endLine)" : nil
                )
            }
            return MeasuredAnswer(text: Self.joinedAnswers(bodies))
        }
    }
}

public extension DigestRenderer {
    /// The join every multi-answer path in this renderer shares: `measured(targets:options:)` above, and the several-declarations case of `renderFileRange` here.
    ///
    /// Every answer after the first opens with ``SourcePassthrough/partMarker``, invisible once rendered, so `SourcePassthrough.fileVerdict(in:of:)` can tell a real part boundary from a blank line and header-shaped line a served-raw body merely happens to contain.
    static func joinedAnswers(_ answers: [String]) -> String {
        answers.enumerated()
            .map { index, answer in index == 0 ? answer : "\(SourcePassthrough.partMarker)\(answer)" }
            .joined(separator: "\n\n")
    }
}

extension DigestRenderer {
    /// One line range walked down a file's declarations — the rules are `renderFileRange`'s.
    struct RangeWalk {
        let span: ClosedRange<Int>
        let children: [Int64: [SymbolRow]]
        let source: [String]

        /// The first line that belongs to `row`: its own first line, or the first line of the doc comment directly above it.
        func start(of row: SymbolRow) -> Int {
            var first = row.line
            while first > 1, first - 2 < source.count {
                let above = source[first - 2].trimmingCharacters(in: .whitespaces)
                if above.hasPrefix("///") {
                    first -= 1
                } else if above.hasSuffix("*/"), let opening = blockCommentOpening(endingAt: first - 1), source[opening - 1].contains("/**") {
                    first = opening
                } else {
                    break
                }
            }
            return first
        }

        /// The line a block comment ending at `line` opens on, or `nil` when none opens above it.
        private func blockCommentOpening(endingAt line: Int) -> Int? {
            var candidate = line
            while candidate >= 1 {
                if source[candidate - 1].contains("/*") {
                    return candidate
                }
                candidate -= 1
            }
            return nil
        }

        /// What the span resolves to among these siblings, in the order they are declared.
        fileprivate func resolve(among siblings: [SymbolRow]) -> DigestRenderer.RangeResolution {
            var blocks: [SymbolRow] = []
            var gap: SymbolRow?
            for row in siblings.sorted(by: { ($0.line, $0.id) < ($1.line, $1.id) })
                where start(of: row) <= span.upperBound && span.lowerBound <= row.endLine
            {
                if span.lowerBound <= row.line, row.endLine <= span.upperBound {
                    blocks.append(row)
                } else if row.kind.isContainer {
                    switch resolve(among: children[row.id] ?? []) {
                    case let .blocks(inner): blocks += inner
                    case let .between(inner): gap = gap ?? inner
                    case .outside: gap = gap ?? row
                    }
                } else {
                    blocks.append(row)
                }
            }
            // Rows sharing one range are one stretch of source: `case a, b, c` is three rows on one line.
            var seen: Set<[Int]> = []
            blocks = blocks.filter { seen.insert([$0.line, $0.endLine]).inserted }
            if !blocks.isEmpty {
                return .blocks(blocks)
            }
            return gap.map(DigestRenderer.RangeResolution.between) ?? .outside
        }
    }
}

// MARK: - Honesty markers

/// What an answer declares about its own limits: the two banners, scoped to the files it actually drew on, and the per-symbol markers for members the parser cannot see.
///
/// Separated from the rendering above because the subject is different — everything before this composes the answer, and everything here says what the answer is not in a position to claim.
extension DigestRenderer {
    /// The parse-error banner for the files an answer actually drew on, as leading lines, or empty when they all parsed cleanly.
    ///
    /// Answer-scoped on purpose: the freshness header already carries the repo-wide count, and repeating it on every answer teaches a reader to ignore it. What the header cannot say — and what decides whether the answer in hand can be trusted — is whether *these* files are among them.
    func parseErrorBanner(touching paths: [String]) throws -> [String] {
        let affected = try Set(store.filesWithParseErrors().map(\.path))
        guard let banner = ParseErrorNotice(paths: paths.filter(affected.contains)).banner else { return [] }
        return [banner, ""]
    }

    /// The parse-error banner over *every* file with a parse error, for the one answer whose claim is an absence.
    ///
    /// The answer-scoped rule above is right wherever an answer is made of the files it cites: what a reader needs is whether *those* parsed. It inverts for "declared, but not under X" — the claim is about a declaration that is not in the list, so the file that would have carried it is by definition not among the paths cited, and a scoped banner would go quiet in exactly the case it exists for.
    ///
    /// Not `private`: `DigestMissAnswer`'s own absence claims (a wrong path, a name nothing declares) need the same repo-wide banner.
    func absenceBanner() throws -> [String] {
        guard let banner = try ParseErrorNotice.acrossRepository(store).absenceBanner else { return [] }
        return [banner, ""]
    }

    /// The parse-error banner for an answer that publishes a *total*, as leading lines.
    ///
    /// The notice takes its scope from the caller rather than choosing one, because the two answers that publish totals count different things: a repository overview counts the repository and a module digest counts a module. What the wording adds over the scoped banner beside it is the arithmetic — a listing can be read against the files the banner names, and a number cannot be read against anything.
    private func countBanner(_ notice: ParseErrorNotice) -> [String] {
        guard let banner = notice.countBanner else { return [] }
        return [banner, ""]
    }

    /// The same, for a count whose *missing* rows would have come from the listed files — the two ambiguity answers, where a lost candidate is exactly why its file is absent from the list beside it.
    private func absenceCountBanner(_ notice: ParseErrorNotice) -> [String] {
        guard let banner = notice.absenceCountBanner else { return [] }
        return [banner, ""]
    }

    /// The note a type digest carries for the one figure in it that no scoping can cover, as leading lines.
    ///
    /// Repo-wide and unconditional on the count's value, because the exposure is: `extensions(ofTypeNamed:)` reads the whole index, an extension truncated out of any file leaves no row to cite, and a type with none at all still publishes that zero by saying nothing. It counts the files instead of listing them — see ``ParseErrorNotice/floorNote(about:)`` for why that is the shape rather than a fourth banner.
    private func extensionCountNote() throws -> [String] {
        guard let note = try ParseErrorNotice.acrossRepository(store).floorNote(about: .typeExtensions) else { return [] }
        return [note, ""]
    }

    /// The guessed-module banner for the files an answer drew on, on the same answer-scoped rule as the one above.
    func guessedModuleBanner(touching paths: [String]) throws -> [String] {
        let affected = try Set(store.filesWithGuessedModule().map(\.path))
        guard let banner = GuessedModuleNotice(paths: paths.filter(affected.contains)).banner else { return [] }
        return [banner, ""]
    }

    private func macroMarker(for row: SymbolRow) -> String {
        let custom = AttributeScanner.customAttributeNames(in: row.signature)
        guard !custom.isEmpty else { return "" }
        return "  ⚠ macro-attributed (@\(custom.joined(separator: " @"))): members may be generated"
    }

    private func synthesizedNote(for row: SymbolRow) -> String {
        switch row.kind {
        case .enumKind:
            "synthesized members (rawValue init, allCases, Codable) not listed"
        default:
            "synthesized members (memberwise init, Codable) not listed"
        }
    }
}

extension DigestRenderer {
    /// Not `private`: `DigestMissAnswer`'s extension listing renders a member line the same way.
    func containerAwareLine(
        _ row: SymbolRow,
        options: DigestOptions,
        indent: String = "  ",
        outlineBudget: inout Int,
        namingChildren: Bool = true
    ) throws -> String {
        guard row.kind.isContainer else {
            return memberLine(row, options: options, indent: indent, outlineBudget: &outlineBudget)
        }
        // Named, not just counted. A container rendered as "— 8 cases/members" answers nothing a reader could
        // act on, and sends the next targeted read straight back to it. The line range beside the names is what
        // a ranged read needs; the signatures stay behind it.
        let children = try namingChildren ? store.children(of: row.id) : []
        let count = try namingChildren ? children.count : store.childCount(of: row.id)
        let noun = row.kind == .enumKind ? "cases/members" : "members"
        let line = "\(decorated(signature: SourceSlicer.shown(row.signature), options: options)) — \(count) \(noun)"
        return indent + line + NestedNames.suffix(for: children) + "  " + row.rangeDescription
    }

    // MARK: Module digest

    private func renderModule(_ module: String, options: DigestOptions) throws -> String {
        let symbols = try store.topLevelSymbols(inModule: module)
        // Scoped to the module's own files rather than the repo's: a module digest is an answer about this module, and naming a broken file in a different one is the decorative counter again.
        //
        // The count wording rather than the plain one, because the line below this banner publishes a
        // total. It says everything the scoped banner says — these files, declarations may be missing —
        // and one thing more, which is that the number is a floor; a reader can see a name absent from
        // the listing, and cannot see anything at all wrong with `12`.
        let affected = try store.filesWithParseErrors().filter { $0.module == module }.map(\.path)
        var lines = countBanner(ParseErrorNotice(paths: affected))
        let guessed = try store.filesWithGuessedModule().filter { $0.module == module }.map(\.path)
        lines += GuessedModuleNotice(paths: guessed).banner.map { [$0, ""] } ?? []
        lines.append("module \(module) — \(symbols.count) top-level declarations")
        var budgeted: [BudgetedLine] = []
        var outlineBudget = Self.outlineCap
        var currentPath = ""
        for row in symbols {
            guard passesAccessFilter(row, options: options) else { continue }
            if row.path != currentPath {
                currentPath = row.path
                budgeted.append(BudgetedLine(text: "", counted: false))
                budgeted.append(BudgetedLine(text: currentPath + ":", counted: false))
            }
            budgeted.append(BudgetedLine(
                text: memberLine(row, options: options, outlineBudget: &outlineBudget),
                counted: true
            ))
        }
        let page = paginate(budgeted, options: options, unit: "declaration lines").map(\.text)
        lines.append(contentsOf: page + DigestSignatureLayout.cutNote(over: page))
        // Withheld, but said out loud. A module digest is a question about a module's surface, so excluding its
        // private declarations is the right default — excluding them *silently* is not, because an answer that
        // looks complete is the one nobody thinks to ask again with `--all`.
        let hidden = symbols.count { !passesAccessFilter($0, options: options) }
        if hidden > 0 {
            lines.append("")
            lines.append("\(hidden) private/fileprivate declaration\(hidden == 1 ? "" : "s") not shown — `--all` (MCP `all: true`) includes them")
        }
        // A module and a type can share a name — every SwiftPM executable target with an eponymous entry-point type does. The module keeps the default, but `where` promises candidates over silent guessing, so the buried type is named rather than discoverable only by already knowing the qualified form.
        let sameNamedTypes = try store.typeDeclarations(named: module)
        if !sameNamedTypes.isEmpty {
            let calls = try Set(sameNamedTypes.map { try qualifiedTarget(of: $0) })
                .sorted()
                .map { "`digest \($0)`" }
                .joined(separator: " or ")
            lines.append("")
            lines.append("a type named \(module) also exists — \(calls) serves it")
        }
        return lines.joined(separator: "\n")
    }

    /// A member's signature as its digest line shows it: whole up to the cap, wrapped at parameter boundaries past it, and cut at the cap where there is no parameter list to wrap.
    private func signatureLines(of row: SymbolRow, options: DigestOptions) -> [String] {
        guard row.signature.count > SourceSlicer.signatureCap else {
            return [decorated(signature: SourceSlicer.tidyingBrackets(in: row.signature), options: options)]
        }
        if let layout = DigestSignatureLayout(decorated(signature: SourceSlicer.tidyingBrackets(in: row.signature), options: options)) {
            return layout.lines
        }
        return [decorated(signature: SourceSlicer.shown(row.signature), options: options)]
    }

    private func decorated(signature: String, options: DigestOptions) -> String {
        options.signaturesOnly ? AttributeScanner.strippingLeadingAttributes(signature) : signature
    }
}

extension DigestRenderer {
    /// One output line and whether it counts against the member cap.
    struct BudgetedLine {
        let text: String
        let counted: Bool
        /// The member this line names, when a suite's helper source can still be inlined beneath it — `nil` for headers, separators, tests, and anything not eligible.
        ///
        /// Inlining is decided after pagination, against only the entries a page actually keeps, so a helper on a page `offset` skips past never touches the digest's helper budget or its withheld count.
        var helper: SymbolRow?
        /// The declaration a file digest's line names, where the line is one of its listed declarations; `nil` elsewhere.
        var row: SymbolRow?

        init(text: String, counted: Bool, helper: SymbolRow? = nil, row: SymbolRow? = nil) {
            self.text = text
            self.counted = counted
            self.helper = helper
            self.row = row
        }
    }

    /// What a file target resolves to: one indexed file, several a suffix matched equally, or none at all.
    enum FileResolution {
        case file(FileRow)
        case ambiguous([String])
        case missing
    }
}
