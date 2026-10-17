//
// Copyright © Agulhas Labs
//

import Foundation

/// The declarations a diff touched in the files the store refused as changed since the build: what the after-edit walk starts from in place of every declaration in those files.
///
/// The whole-file rule exists because a hunk's lines cannot be laid over the index's current ranges: a deletion has no extent to intersect, and an added file is new throughout. Comparing both sides' parses instead answers both — a removed or renamed declaration is read off the before side and seeded by its old name, an added file's declarations are all added — and a file whose change the comparison cannot fully account for (text outside every declaration such as an import, but not a comment, which changes no behaviour; a hunk no declaration explains, a side that did not parse or read) is still seeded whole, as is one with a touched file-scope operator, which leaves no identifier to scan for.
struct AffectedAfterEditSeeds {
    /// The names to scan for, for every file the comparison accounted for.
    var seeds: [AffectedNameSeed] = []
    /// The touched declarations the index holds, so a touched test is listed as affected itself.
    var rows: [SymbolRow] = []
    /// The files seeded from their touched declarations; every other refused file is seeded whole.
    var files: Set<String> = []
    /// The refused files seeded whole because they were committed since the build (or their commit time could not be read), so the diff against `HEAD` is no account of what changed in them.
    var committedSinceBuild: Set<String> = []
    /// Whether `committedSinceBuild` is every refused file because `HEAD` moved since the build (or when it last moved could not be read).
    var headMovedSinceBuild = false
    /// The refused files whose only change is a comment, so nothing was walked from them and the written-name walk skips them too.
    var commentOnly: Set<String> = []
    /// The refused files seeded whole for a reason other than being committed since the build, by reason: the paths each reason refused.
    var seededWhole: [String: [String]] = [:]
    /// For a seed name, the outermost types declaring the touched declarations it stands for, a removed one aside: seeded in its place when its own call-site scan finds no site, since a declaration no site names is reached, if at all, through its type — a witness the language or a framework calls, a coding key, a decoding initializer.
    var fallbacks: [String: Set<AffectedNameSeed>] = [:]
    /// The names of the declarations the diff removed, a rename's old name among them: no store holds a row for one, and a call left unedited can now resolve to an overload the diff did not touch.
    var removed: [AffectedNameSeed] = []
    /// The names of the callables the diff kept but changed the signature of: the store's row is the new declaration, and a call left unedited can now resolve to an overload the diff did not touch, as after a removal.
    var signatureChanged: [AffectedNameSeed] = []
    /// The names of the types each file's changes are seeded by, so a type is rooted only in the file its seed came from.
    var typeSeeds: [String: Set<String>] = [:]

    /// The names followed to their call sites as well as resolved: the removed declarations' and those whose signature changed, each once.
    var seededByName: [AffectedNameSeed] {
        removed + signatureChanged.filter { !removed.contains($0) }
    }

    /// How many distinct names the walk was seeded with, one name declared in two modules counted once.
    var nameCount: Int {
        Set(seeds.map(\.name)).count
    }

    /// The seed names, sorted, the first eight written out and the rest counted.
    var namesListed: String {
        let names = Set(seeds.map(\.name)).sorted()
        return names.prefix(8).joined(separator: ", ") + (names.count > 8 ? ", +\(names.count - 8) more" : "")
    }

    /// The touched declarations of every file among `diffs` whose change the comparison accounted for.
    static func of(_ diffs: [FileDiff], store: IndexStore) throws -> AffectedAfterEditSeeds {
        var result = AffectedAfterEditSeeds()
        var seen: Set<AffectedNameSeed> = []
        for diff in diffs.sorted(by: { $0.path < $1.path }) {
            var outside = diff.outside
            outside.removeAll { $0.category == .comments }
            if diff.unreadableSides != nil {
                result.seededWhole["a side is not text", default: []].append(diff.path)
                continue
            }
            if !diff.parseErrorSides.isEmpty {
                result.seededWhole["a side did not parse", default: []].append(diff.path)
                continue
            }
            if !outside.isEmpty {
                result.seededWhole["text outside its declarations changed", default: []].append(diff.path)
                continue
            }
            if !diff.lineChanges.isEmpty {
                result.seededWhole["a hunk no declaration explains", default: []].append(diff.path)
                continue
            }
            guard let module = try store.fileRow(path: diff.path)?.module else {
                result.seededWhole["not in the index", default: []].append(diff.path)
                continue
            }
            let rows = try store.symbols(inFile: diff.path)
            var touchedRows: [SymbolRow] = []
            var fileSeeds: [AffectedNameSeed] = []
            var fileFallbacks: [String: Set<AffectedNameSeed>] = [:]
            var fileRemoved: [AffectedNameSeed] = []
            var fileSignatureChanged: [AffectedNameSeed] = []
            let changes = diff.changes.filter { !($0.kind == .moved && $0.movedIntact) }
            if changes.isEmpty {
                result.commentOnly.insert(diff.path)
                continue
            }
            // An operator is no name a site spells: one declared in a type seeds the type, and one at file scope, which no type declares, seeds its whole file.
            guard !changes.contains(where: { $0.containerPath.isEmpty && !AffectedNameSeed.isIdentifier(CallSiteScanner.baseName(of: $0.name)) }) else {
                result.seededWhole["a file-scope operator changed", default: []].append(diff.path)
                continue
            }
            for change in changes {
                let wholeContainer = change.memberCount != nil
                var changeRows: [SymbolRow] = []
                if let range = change.newRange {
                    changeRows = rows.filter { row in
                        wholeContainer
                            ? row.line >= range.line && row.endLine <= range.endLine
                            : row.name == change.name && row.kind == change.symbolKind && row.line <= range.endLine && row.endLine >= range.line
                    }
                }
                touchedRows += changeRows
                let changeSeeds = seeds(of: change, module: module, throughItsType: !wholeContainer && reachedThroughItsType(change, rows: changeRows))
                // A removed declaration, a rename's old name among them, is expected to have no site left: its callers are seeded by what they call now.
                if change.kind != .removed, let outermost = outermostType(of: change) {
                    for seed in changeSeeds where seed.kind == change.symbolKind || seed.kind == .initializer {
                        fileFallbacks[seed.name, default: []].insert(AffectedNameSeed(name: outermost, module: module, kind: .structKind))
                    }
                }
                fileSeeds += changeSeeds
                if change.kind == .removed {
                    fileRemoved += changeSeeds
                } else if change.kind == .changed, change.signatureChanged, [.function, .initializer, .subscriptKind].contains(change.symbolKind) {
                    fileSignatureChanged += changeSeeds
                }
            }
            for row in touchedRows where row.kind != .extensionKind {
                try fileSeeds.append(AffectedNameSeed.callSite(of: row, in: store))
            }
            fileSeeds = fileSeeds.filter { AffectedNameSeed.isIdentifier($0.name) }
            // A file whose changes leave nothing to scan for is seeded whole rather than from nothing.
            guard !fileSeeds.isEmpty else {
                result.seededWhole["nothing it touched has a name to scan for", default: []].append(diff.path)
                continue
            }
            result.files.insert(diff.path)
            result.rows += touchedRows
            result.seeds += fileSeeds.filter { seen.insert($0).inserted }
            result.fallbacks.merge(fileFallbacks) { $0.union($1) }
            for seed in fileRemoved where AffectedNameSeed.isIdentifier(seed.name) && !result.removed.contains(seed) {
                result.removed.append(seed)
            }
            for seed in fileSignatureChanged where AffectedNameSeed.isIdentifier(seed.name) && !result.signatureChanged.contains(seed) {
                result.signatureChanged.append(seed)
            }
            result.typeSeeds[diff.path] = Set(fileSeeds.filter { $0.kind == .structKind }.map(\.name))
        }
        return result
    }

    /// Whether a time git read is after the build, or could not be read: git's times are whole seconds, floored, and the anchor is fractional, so a time in the anchor's own second counts as after it.
    static func isSinceBuild(_ time: Double?, anchor: Double) -> Bool {
        time.map { $0 + 1 > anchor } ?? true
    }

    /// Adds to the first hop's `frontier` the types a seed name falls back to where its own scan `found` no site, and returns the names to scan again: those new to the frontier, and those now asked in a wider shape than they were scanned in.
    static func fallingBack(
        to fallbacks: [String: Set<AffectedNameSeed>],
        found: [String: [NameMention]],
        excluding: Set<String>,
        frontier: inout [String: Set<String>],
        shapes: inout [String: CallSiteScanner.SiteShape]
    ) -> Set<String> {
        var rescan: Set<String> = []
        for name in Array(frontier.keys) where (found[name] ?? []).allSatisfy({ excluding.contains($0.path) }) {
            for seed in fallbacks[name] ?? [] {
                let shape = seed.shape.widened(by: shapes[seed.name])
                if frontier[seed.name] == nil || shape != shapes[seed.name] {
                    rescan.insert(seed.name)
                }
                shapes[seed.name] = shape
                frontier[seed.name, default: []].insert(seed.module)
            }
        }
        return rescan
    }

    /// The outermost type a member change sits in — `Point` for `Point.CodingKeys` — or `nil` at file scope and for a type, or an extension, changed itself.
    private static func outermostType(of change: DeclarationChange) -> String? {
        guard !change.containerPath.isEmpty, !change.symbolKind.isTypeDeclaration, change.symbolKind != .extensionKind else { return nil }
        var depth = 0
        let path = change.containerPath
        let end = path.indices.first { index in
            switch path[index] {
            case "<", "[", "(": depth += 1
            case ">", "]", ")": depth -= 1
            case "." where depth == 0: return true
            default: break
            }
            return false
        } ?? path.endIndex
        return DeclaredTypeName.last(ofPath: path[..<end])
    }

    /// Each side of one file the change set names, compared as `diff` compares it: the before side from the range's start, or `HEAD`, and the after side from its end, or the working tree.
    static func fileDiffs(of changes: [GitContext.Change], range: AffectedOptions.CommitRange?, git: GitContext, repositoryRoot: URL) throws -> [FileDiff] {
        guard !changes.isEmpty else { return [] }
        let from = range?.from ?? "HEAD"
        var requests = changes.map { (rev: from, path: $0.renamedFrom ?? $0.path) }
        if let range {
            requests += changes.map { (rev: range.to, path: $0.path) }
        }
        let blobs = try git.blobs(requests)
        return changes.enumerated().map { offset, change in
            let new = range == nil ? try? Data(contentsOf: repositoryRoot.appendingPathComponent(change.path)) : blobs[changes.count + offset]
            return DiffGatherer.fileDiff(change, old: blobs[offset], new: new)
        }
    }

    /// Whether a change reaches its callers through the type declaring it as well as by its own name, so that type is seeded too.
    ///
    /// An operator, applied by a symbol no site spells as a name; a witness the language calls on the type's behalf, never by a written name; an enum case added or removed, which `allCases`, a `switch` and synthesized `Codable` and `rawValue` see without spelling it; a stored instance property, whose default and type the memberwise initializer and synthesized `Codable` read without spelling it. A property the index holds no row for, a removed one included, may have been stored, and counts as one.
    private static func reachedThroughItsType(_ change: DeclarationChange, rows: [SymbolRow]) -> Bool {
        let base = CallSiteScanner.baseName(of: change.name)
        if !AffectedNameSeed.isIdentifier(base) || implicitlyCalled.contains(base) {
            return true
        }
        if change.symbolKind == .enumCase, change.kind == .added || change.kind == .removed {
            return true
        }
        return change.symbolKind == .variable && (rows.isEmpty || rows.contains { $0.isStored && !$0.isStatic })
    }

    /// The base names of the witnesses the language calls without a site spelling them: `description` in an interpolation, `hash(into:)` in a `Set`, `wrappedValue` behind `@T`, `callAsFunction` behind `x(1)`, `makeIterator` behind `for in`, `encode(to:)` behind an encoder, a result builder's `build` functions behind its attribute.
    private static let implicitlyCalled: Set<String> = [
        "buildArray", "buildBlock", "buildEither", "buildExpression", "buildFinalResult", "buildLimitedAvailability", "buildOptional", "buildPartialBlock",
        "callAsFunction", "customMirror", "debugDescription", "description", "dynamicallyCall", "encode", "errorDescription", "failureReason", "hash", "hashValue",
        "helpAnchor", "makeAsyncIterator", "makeIterator", "next", "projectedValue", "recoverySuggestion", "wrappedValue",
    ]

    /// The names one change is seeded by, read off whichever side holds them: a removed declaration and a wholly removed container's functions from the before side, the container type a subscript or an extension stands for, and the type declaring a change reached through it.
    private static func seeds(of change: DeclarationChange, module: String, throughItsType: Bool) -> [AffectedNameSeed] {
        let containerType = change.containerPath.isEmpty ? nil : DeclaredTypeName.last(ofPath: change.containerPath)
        var seeds: [AffectedNameSeed] = []
        if throughItsType, let containerType {
            seeds.append(AffectedNameSeed(name: containerType, module: module, kind: .structKind))
        }
        switch change.symbolKind {
        case .initializer, .subscriptKind:
            if let containerType {
                seeds.append(AffectedNameSeed(name: containerType, module: module, kind: change.symbolKind == .initializer ? .initializer : .structKind))
            }
        case .extensionKind:
            seeds.append(AffectedNameSeed(name: DeclaredTypeName.last(ofPath: change.name), module: module, kind: .extensionKind))
        default:
            seeds.append(AffectedNameSeed(name: CallSiteScanner.baseName(of: change.name), module: module, kind: change.symbolKind))
        }
        if change.kind == .removed {
            seeds += change.nestedFunctions.map { AffectedNameSeed(name: CallSiteScanner.baseName(of: $0.name), module: module, kind: .function) }
        }
        return seeds
    }
}
