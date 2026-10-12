//
// Copyright © Agulhas Labs
//

import Foundation
import IndexStoreDB

/// The lazily opened semantic layer over a discovered index store: USR resolution and relation queries.
///
/// USRs are resolved at query time from the syntactic declaration's location — never persisted (Docs/Design.md §2). Staleness is anchored to the store's newest unit mtime: a symbol whose file is newer than the last build refuses semantic answers, because only a *build* can heal this axis.
///
/// Concurrency contract: owned by one engine and accessed serially, same as `SiftEngine`.
final class SemanticStore: @unchecked Sendable {
    private let database: IndexStoreDB
    let provenance: DiscoveredStore.Provenance
    /// The SwiftPM package directory the store was built in, empty for the root's (``DiscoveredStore/package``).
    let package: String
    /// The root of the tree the store answers for: the repo-relative path of a declaration it is asked about is spelled under it, as the build recorded the file.
    let repoRoot: URL
    /// Where the store was ingested, which names the store as well — its path and its directory's identity.
    ///
    /// The engine re-probes per query and reopens when discovery yields another cache.
    let cache: SemanticCache
    /// The store's "last built" moment at open; the engine reopens when newer units land, so a stale anchor never outlives a build.
    let newestUnitDate: Date
    /// Guards ``newestUnits`` and ``unitLookups``, since the open store is shared across queries.
    private let unitLock = NSLock()
    /// Each absolute path the store was asked about, as the store spells it, to its newest unit's date, `nil` where it holds none: a store's units do not change while it is open, so each path is looked up once per open.
    private var newestUnits: [String: Date?] = [:]
    private var lookups = 0

    /// Opens the store, ingesting its units into a cache of its own (``SemanticCache``), so a warm reopen is instant and no other store's units ever answer for it.
    ///
    /// `beforeRead` runs once the cache is ready and before IndexStoreDB reads the store: a test's way into the moment a rebuild landing as a cold import starts.
    init(discovered: DiscoveredStore, repoRoot: URL, newestUnitDate: Date, cache: SemanticCache, beforeRead: () -> Void = {}) throws {
        let library = try IndexStoreLibrary(dylibPath: Self.libIndexStorePath())
        try cache.prepare()
        beforeRead()
        let database = try IndexStoreDB(
            storePath: discovered.path.path,
            databasePath: cache.directory.path,
            library: library,
            waitUntilDoneInitializing: true,
            listenToUnitEvents: false
        )
        // The cache was named for the store before IndexStoreDB read it, through a cold import that can run for
        // minutes, and a store replaced in between filled it with the new store's units. So it goes before this open
        // lets go of it, and nothing the open read is answered from — this query's or any later one's, whatever its
        // budget let it wait for (``SemanticCache/setAside()``).
        guard cache.stillNamesItsStore else {
            withExtendedLifetime(database) { cache.setAside() }
            throw ReplacedWhileRead()
        }
        self.database = database
        provenance = discovered.provenance
        package = discovered.package
        self.repoRoot = repoRoot
        self.cache = cache
        self.newestUnitDate = newestUnitDate
    }

    /// The toolchain's indexstore library, via xcrun with the default Xcode layout as fallback.
    static func libIndexStorePath() throws -> String {
        let defaultPath = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "swift"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        guard (try? process.run()) != nil else {
            ProcessStreams.abandon(stdout, stderr)
            return defaultPath
        }
        // Through the shared drain, like every other subprocess here. An unread stderr pipe blocks the child
        // once it fills at 64 KB; `xcrun --find swift` would rarely say that much, but "the child cannot say
        // much" is a property of the child, and the next caller to copy this shape gets a different one.
        let streams = ProcessStreams.drain(stdout: stdout, stderr: stderr)
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let swiftPath = String(data: streams.output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !swiftPath.isEmpty else { return defaultPath }
        let candidate = URL(fileURLWithPath: swiftPath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("lib/libIndexStore.dylib")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate.path : defaultPath
    }

    /// Resolves a syntactic declaration to its USR among canonical occurrences, `nil` for a declaration in a file the store does not answer for (``answers(forFile:)``).
    ///
    /// The store names functions in their labeled form (`save(_:to:)`), so the labeled name is tried first, the bare base name as fallback. Attributed declarations start a line or two above where the store anchors them, so any line inside the declaration's range matches (exact line preferred).
    ///
    /// An occurrence counts only in the row's own file, spelled under ``repoRoot`` as the build may have recorded it: another file ending in the same path, in a nested package or a dependency, is never the row's.
    func usr(for row: SymbolRow) -> String? {
        guard answers(forFile: row.path) else { return nil }
        let name = Self.asTheStoreSpellsIt(row.name)
        var candidates = canonicalOccurrences(ofName: name)
        if candidates.isEmpty, row.name != row.baseName {
            candidates = canonicalOccurrences(ofName: Self.asTheStoreSpellsIt(row.baseName))
        }
        let spellings = Set(Self.spellings(ofFile: row.path, under: repoRoot))
        let inFile = candidates.filter { spellings.contains($0.location.path) }
        if let exact = inFile.first(where: { $0.location.line == row.line }) {
            return exact.symbol.usr
        }
        let range = row.line ... max(row.line, row.endLine)
        return inFile.first { range.contains($0.location.line) }?.symbol.usr
    }

    /// A name sift stores, spelled as the compiler's index store records it: without the backticks sift keeps around a raw identifier, which the store never carries.
    ///
    /// Applied only where the store is asked; sift's own stored name keeps them, and a raw identifier cannot contain one. An operator function is called with no labels, and the store names it so — `+(_:_:)` for sift's `+(lhs:rhs:)` — so its labels are blanked.
    private static func asTheStoreSpellsIt(_ name: String) -> String {
        let bare = name.replacingOccurrences(of: "`", with: "")
        guard SymbolNaming.isOperator(bare), let open = bare.firstIndex(of: "("), bare.hasSuffix(")") else { return bare }
        let labels = bare[bare.index(after: open)...].dropLast().split(separator: ":", omittingEmptySubsequences: false).dropLast()
        return bare[...open] + labels.map { _ in "_:" }.joined() + ")"
    }

    /// Whether the store holds a unit for the source file at the absolute `path`, spelled as the build recorded it.
    func hasUnit(forFile path: String) -> Bool {
        newestUnit(ofFile: path) != nil
    }

    /// The date of the newest unit the store holds for the source file at the absolute `path`, spelled as the build recorded it, `nil` where it holds none; asked of the store once per path per open.
    func newestUnit(ofFile path: String) -> Date? {
        unitLock.withLock {
            if let known = newestUnits[path] {
                return known
            }
            lookups += 1
            let date = database.dateOfLatestUnitFor(filePath: path)
            newestUnits[path] = .some(date)
            return date
        }
    }

    /// How many newest-unit lookups the store has paid for since it opened, which is what makes the one-per-path claim checkable.
    var unitLookups: Int {
        unitLock.withLock { lookups }
    }

    /// Whether the store answers for the file at the repo-relative `path` at all (``DiscoveredStore/answers(package:forFile:)``).
    func answers(forFile path: String) -> Bool {
        DiscoveredStore.answers(package: package, forFile: path)
    }

    /// The absolute spellings a build may have recorded the repo-relative `path` under `root` by (``FileSpellings``), every one of them, the filesystem asked.
    static func spellings(ofFile path: String, under root: URL) -> [String] {
        var spellings = FileSpellings(ofFile: path, under: root)
        return spellings.all()
    }

    /// For each of `names`, each distinct place the newest units of the file at the absolute `path` record a symbol of that base name referenced at, marked with whether the scanned shape takes a symbol recorded there by its compound name, a declaration and an implicit occurrence left out (``fromCurrentUnits(_:)``): what the last build saw the file refer to, to set against what it writes now.
    func writtenPlaces(of names: ScannedNames, inFile path: String) -> [String: [ScannedNames.RecordedPlace]] {
        let byBare = Dictionary(names.names.map { ($0.replacingOccurrences(of: "`", with: ""), $0) }) { first, _ in first }
        var places: [String: Int] = [:]
        var written: [String: [ScannedNames.RecordedPlace]] = [:]
        for occurrence in fromCurrentUnits(database.symbolOccurrences(inFilePath: path))
            where !occurrence.roles.contains(.implicit) && !occurrence.roles.contains(.definition) && !occurrence.roles.contains(.declaration)
        {
            guard let name = byBare[String(occurrence.symbol.name.prefix { $0 != "(" })] else { continue }
            let isTakenByName = names.accepts(symbolNamed: occurrence.symbol.name, as: name)
            let key = "\(name):\(occurrence.location.line):\(occurrence.location.utf8Column)"
            if let index = places[key] {
                if isTakenByName {
                    written[name]?[index].isTakenByName = true
                }
                continue
            }
            places[key] = written[name, default: []].count
            written[name, default: []].append(ScannedNames.RecordedPlace(line: occurrence.location.line, column: occurrence.location.utf8Column, isTakenByName: isTakenByName))
        }
        return written
    }

    /// Call sites of the symbol, and the places it is named without a call, each with the calling symbol's name, the location and the unit that recorded it — a macro expansion's copy of a written one left out (``written(_:)``).
    ///
    /// A call is recorded `ref|call`, and a function handed on unapplied — `.map(T.f)`, `T.f(x:)` as a value, `#selector(f)` — `ref` alone, related only to the symbol containing it; asked for calls alone, the store answered "no callers" of a function used exactly that way, and the answer was believed. So every reference is taken, and one with no call is marked ``Hit/uncalled``.
    func callers(ofUSR usr: String) -> [Hit] {
        Self.written(occurrences(ofUSR: usr, roles: .reference)).map { kept in
            var hit = Hit(kept.occurrence, name: name(of: kept, by: [.calledBy, .containedBy]) ?? "(unknown caller)")
            hit.uncalled = !kept.occurrence.roles.contains(.call)
            return hit
        }
    }

    /// Reads and writes of a property or subscript, each with the enclosing symbol's name, the unit that recorded it, and the access the store recorded there — neither, for a reference that only names it.
    ///
    /// A property is never *called*, so `callers` finds nothing for one however much it is used. Verified empirically against a real store: a use of a `var` or `let` written in code — stored or computed, static or instance, from its own file, another file or another module — is recorded on the property's own USR as `ref|read`, `ref|write`, or both at once for a compound assignment (`+=`), related only to the symbol containing it. A subscript is recorded the same way; a key path to a property records a read, and so does a property reached through a dynamic member — `$model.level` on a `@Bindable`, `box.level` on a `@dynamicMemberLookup` type; and a protocol requirement read through a generic or an existential records a dynamic read on the requirement. An argument to a memberwise initializer, `Point(x: 1, y: 2)`, is a plain `ref` at its label, with neither access. The `call` goes to the getter or setter *accessor* instead — a USR of its own, recorded as an implicit call at the same line and column — so the property's own occurrences find each use exactly once, with no accessor to look up and none to deduplicate against.
    ///
    /// **What it cannot see**: code the compiler synthesizes reads and writes a property with no occurrence recorded — an `Equatable`, `Hashable` or `Codable` conformance's `==`, `hash(into:)` and `encode(to:)` — and access by name at runtime is no occurrence either. **What it drops**: a macro expansion's copy of a written use (``written(_:)``), and an implicit use inside an accessor of the property or of either sibling (``Property/isGenerated(_:)``) — `@Observable` rewrites each property's getter, setter and modify coroutine to read its key path, recorded as five implicit reads at the `@Observable` attribute, which listed a property nothing uses as read three times over.
    ///
    /// **What it adds**: a use through a property wrapper's `$` or `_` sibling, which the store records on the sibling's own USR (see `property`, below), marked with the sibling it went through — and, where the store records one on the property itself, the sibling its spelling names (``Property/sibling(spelling:in:)``), with no access said, since the store records such a use as a read whatever it does. **What it relabels**: a use inside a `didSet` or `willSet` a macro moved into generated storage (``Property/movedObserver(containing:)``) — recorded at the macro, and nowhere where it is written.
    ///
    /// The role filter matches an occurrence carrying *any* of the roles given — read in IndexStoreDB's own source — so one query returns reads, writes, read-writes and plain references; a definition carries none of them.
    func uses(ofUSR usr: String) -> [Use] {
        var sources = SourceLines()
        return uses(ofUSR: usr, sources: &sources)
    }

    /// The same uses, reading sibling spellings through a caller's line cache, so one query that also asks for the references reads each use file once.
    func uses(ofUSR usr: String, sources: inout SourceLines) -> [Use] {
        let property = property(ofUSR: usr)
        return property.targets.flatMap { target in
            Self.written(occurrences(ofUSR: target.usr, roles: [.reference, .read, .write]))
                .filter { !property.isGenerated($0.occurrence) }
                .map { kept in
                    let observer = property.movedObserver(containing: kept.occurrence)
                    // A use spelled through a sibling the store records on the property itself carries a read whatever it does, so its access is not said.
                    let spelled = target.through == nil ? property.sibling(spelling: kept.occurrence, in: &sources) : nil
                    return Use(
                        hit: Hit(kept.occurrence, name: observer ?? name(of: kept, by: .containedBy) ?? "(top level)", through: target.through ?? spelled),
                        reads: spelled == nil && kept.occurrence.roles.contains(.read),
                        writes: spelled == nil && kept.occurrence.roles.contains(.write),
                        inMovedObserver: observer != nil,
                        accessRecorded: spelled == nil
                    )
                }
        }
    }

    /// Every use of an enum case, each with the enclosing symbol's name and the unit that recorded it.
    ///
    /// An enum case is never read or written and is called only sometimes, so neither `uses` nor `callers` sees one whole. Verified empirically against a real store: every use of a case written in code — `.fast` in an expression, `Mode.fast` qualified, `case .fast:` in a switch, `if case .fast = x`, `x == .fast`, from its own file, another file or another module — is recorded on the case's own USR as a plain `ref`, related only to the symbol containing it. Building a case with associated values (`.value(3)`, `Mode.value(4)`) adds `call`; matching one (`case .value(let x)`, `case let .pair(left, _)`) does not, and neither does an unapplied `Mode.value`. So the references are the uses, each found exactly once, and none carries an access; a macro expansion's copy of one is left out (``written(_:)``). Code the compiler synthesizes names a case with no occurrence recorded: `CaseIterable`'s `allCases` and a raw value's `init(rawValue:)` reach one nothing lists.
    func caseUses(ofUSR usr: String) -> [Use] {
        Self.written(occurrences(ofUSR: usr, roles: .reference)).map { kept in
            Use(
                hit: Hit(kept.occurrence, name: name(of: kept, by: .containedBy) ?? "(top level)"),
                reads: false,
                writes: false
            )
        }
    }

    /// Every recorded reference to the symbol, each with the enclosing symbol's name — the sweep view behind `--refs`.
    ///
    /// A superset of `callers`: call sites carry both `.call` and `.reference`, and type mentions carry only `.reference`, which is exactly what a delete or rename sweep needs and `callers` cannot see. Definitions are excluded — they carry `.definition`, not `.reference`.
    ///
    /// Read by the rules a property's uses are (see `uses`, above), since a sweep edits the same lines: a reference through a wrapper's `$` or `_` sibling is one to rename, marked with the sibling — whether the store records it on the sibling or, spelled so in the source, on the property itself; an implicit one inside an accessor of the property or of either sibling has nothing written there to rename, so it is dropped; and one inside an observer a macro moved sits at the macro's line, where there is nothing to rename either, so it is dropped too — the renderer says where that leaves a gap. A mention inside a declaration a macro generated is dropped as well (``isGeneratedMention(_:implicitDeclarations:)``): `@Observable` storage names its property's type at the attribute, where nothing is written.
    ///
    /// **This covers code only.** Comments and string literals are not occurrences, so a doc comment naming the symbol is invisible here; `where --refs` lists such mentions apart, from the working tree (``NonCodeMentions``), so an empty result does not read as "nothing left to change".
    func references(ofUSR usr: String) -> [Hit] {
        var sources = SourceLines()
        return references(ofUSR: usr, sources: &sources)
    }

    /// The same references, reading sibling spellings through a caller's line cache, shared with the uses for one query.
    func references(ofUSR usr: String, sources: inout SourceLines) -> [Hit] {
        referencesAndGeneratedMentions(ofUSR: usr, sources: &sources).hits
    }

    /// The same references, with the `path:line` of each mention the sweep sets aside as one a macro generated, so the sweep that leaves them out can say how many; a line that also holds a mention written there is among them.
    ///
    /// One read of the store per target serves both, so the count and the list cannot disagree about what was set aside.
    func referencesAndGeneratedMentions(ofUSR usr: String, sources: inout SourceLines) -> (hits: [Hit], generatedLines: Set<String>) {
        let property = property(ofUSR: usr)
        var implicitDeclarations: [String: Bool] = [:]
        var hits: [Hit] = []
        var generatedLines: Set<String> = []
        for target in property.targets {
            for kept in Self.written(occurrences(ofUSR: target.usr, roles: .reference)) {
                let occurrence = kept.occurrence
                guard !property.isGenerated(occurrence), property.movedObserver(containing: occurrence) == nil else { continue }
                if isGeneratedMention(occurrence, implicitDeclarations: &implicitDeclarations) {
                    generatedLines.insert("\(occurrence.location.path):\(occurrence.location.line)")
                    continue
                }
                let through = target.through ?? property.sibling(spelling: occurrence, in: &sources)
                hits.append(Hit(occurrence, name: name(of: kept, by: [.containedBy, .calledBy]) ?? "(top level)", through: through))
            }
        }
        return (hits, generatedLines)
    }

    /// Declarations that override the symbol, or witness it: never one a protocol declares, which restates it (``implementedRequirements(ofUSR:)``).
    ///
    /// The store answers by the occurrence's roles, so a restated property's own getter — an `overrideOf` of the base's getter, related to the property only as its accessor — comes back too; only an occurrence whose relation to the symbol is the override is kept.
    ///
    /// A witness picked at a conformance is listed where it is written. Verified empirically against a real store: a protocol extension's default that `struct Depot: Refined` takes is recorded as an implicit occurrence of the default at `Depot`'s name, contained by `Depot`, beside the default's own definition, and a function in a type's body that `extension Crate: Named {}` makes a witness is recorded so at the extension (``implementedRequirements(ofUSR:)``). So such an occurrence stands for the witness's written definitions, each listed once however many conformers take it; one whose witness has no written definition in the tree is kept where it is. `inTree` judges a definition's absolute path: the store also holds definitions outside it — a library's member read from its SDK interface (at line 0), a dependency's checkout under `.build` — and a synthesized member has none at all.
    func overrides(ofUSR usr: String, inTree: (String) -> Bool) -> [Hit] {
        var listed: Set<Anchor> = []
        let overriding = occurrences(relatedToUSR: usr, roles: .overrideOf).filter { occurrence in
            occurrence.relations.contains { $0.symbol.usr == usr && $0.roles.contains(.overrideOf) }
        }
        .flatMap { occurrence in
            guard occurrence.roles.contains(.implicit) else { return [occurrence] }
            let definitions = occurrences(ofUSR: occurrence.symbol.usr, roles: .definition).filter {
                !$0.roles.contains(.implicit) && $0.location.line > 0 && inTree($0.location.path)
            }
            return definitions.isEmpty ? [occurrence] : definitions
        }
        .filter { occurrence in
            !occurrence.relations.contains { $0.roles.contains(.childOf) && $0.symbol.kind == .protocol } && listed.insert(Anchor(occurrence)).inserted
        }
        return Self.written(overriding).map { kept in
            Hit(kept.occurrence, name: displayName(of: kept.occurrence.symbol))
        }
    }

    /// The declarations the symbol's definition is recorded as implementing: a protocol requirement it satisfies, a superclass member it overrides.
    ///
    /// The other end of ``overrides(ofUSR:)``: the definition carries an `overrideOf` relation to each, or, where an extension declares the conformance, an implicit occurrence at the extension carries it and the definition does not. A call through one of them is recorded against it, or (inside a library) not at all, never against the symbol, so the symbol's own callers are only its direct ones. The declaring protocol or class is named from the store alone (``ImplementedRequirement/owner``).
    func implementedRequirements(ofUSR usr: String) -> [ImplementedRequirement] {
        var seen: Set<String> = []
        let recorded = occurrences(ofUSR: usr, roles: [.definition, .overrideOf])
        // A requirement is a child of its protocol, a default implementation a child of the protocol's extension.
        let restated = recorded.contains { occurrence in
            occurrence.roles.contains(.definition) && occurrence.relations.contains { $0.roles.contains(.childOf) && $0.symbol.kind == .protocol }
        }
        return recorded.flatMap { occurrence in
            occurrence.relations.filter { $0.roles.contains(.overrideOf) }.map(\.symbol)
        }
        .filter { seen.insert($0.usr).inserted }
        .map { ImplementedRequirement(name: displayName(of: $0), owner: owner(ofRequirement: $0.usr), restated: restated) }
    }

    /// The protocol or class that declares the requirement `usr`: its definition's parent where the store holds the definition, else the symbol whose USR is the longest prefix of the requirement's, as a member's USR extends its container's — and `nil` where the store holds neither.
    private func owner(ofRequirement usr: String) -> ImplementedRequirement.Owner? {
        let parents = occurrences(ofUSR: usr, roles: .definition).compactMap { definition in
            definition.relations.first { $0.roles.contains(.childOf) }?.symbol
        }
        if let parent = parents.first, let owner = ImplementedRequirement.Owner(parent.name, kind: parent.kind) {
            return owner
        }
        let prefixes = usr.indices.dropFirst("s:".count + 1).reversed().map { String(usr[..<$0]) }
        for prefix in prefixes {
            // Unfiltered on purpose: only the symbol's name and kind are read, which every unit records alike, so a unit older than its file's last edit cannot misplace anything here.
            var found: Symbol?
            _ = database.forEachSymbolOccurrence(byUSR: prefix, roles: .all) { occurrence in
                found = occurrence.symbol
                return false
            }
            if let found, let owner = ImplementedRequirement.Owner(found.name, kind: found.kind) {
                return owner
            }
        }
        return nil
    }

    /// Types the store records as inheriting from / conforming to the symbol (catches what name-matching can't, e.g. conformance via typealias).
    ///
    /// The store writes inheritance as an occurrence *of the base* at the conformer's clause, with the conformer in the relation (`ref|baseOf`, relation `Child:[baseOf]` — verified empirically against a real store).
    func semanticConformers(ofUSR usr: String) -> [Hit] {
        Self.written(occurrences(ofUSR: usr, roles: .baseOf)).map { kept in
            Hit(kept.occurrence, name: relatedName(of: kept.occurrence, by: .baseOf) ?? "(unknown)")
        }
    }

    /// Types the store records as conforming to, or subclassing, a protocol or class named `name` other than `usr`: the clauses of another type of the same name, which a scan by written name cannot tell from the asked one's.
    ///
    /// A type of the name that itself inherits from `usr`, however indirectly, is no other: its own conformers conform to `usr` too. Nor is a clause whose inheritor the store shows inheriting from `usr` through any chain (`final class Lantern: Answer, Middle` where `Middle` refines it): that row conforms to both, and stays.
    func conformersOfOtherTypes(named name: String, besides usr: String) -> [Hit] {
        let others = Set(canonicalOccurrences(ofName: name).filter { [.protocol, .class].contains($0.symbol.kind) && $0.symbol.usr != usr }.map(\.symbol.usr))
        return others.filter { !inherits($0, from: usr) }.sorted().flatMap { other in
            let declaredIn = occurrences(ofUSR: other, roles: .definition).first?.location.path
            return Self.written(occurrences(ofUSR: other, roles: .baseOf)).filter { kept in
                !kept.occurrence.relations.contains { relation in
                    relation.roles.contains(.baseOf) && extended(by: relation.symbol.usr).contains { inherits($0, from: usr) }
                }
            }.map { kept in
                var tagged = Hit(kept.occurrence, name: relatedName(of: kept.occurrence, by: .baseOf) ?? "(unknown)")
                tagged.protocolPath = declaredIn
                return tagged
            }
        }
    }

    /// The declaration `usr` and, where it is an extension, the type it extends: the inheritor a conformance an extension declares belongs to.
    private func extended(by usr: String) -> [String] {
        [usr] + occurrences(relatedToUSR: usr, roles: .extendedBy).filter { occurrence in
            occurrence.relations.contains { $0.symbol.usr == usr && $0.roles.contains(.extendedBy) }
        }.map(\.symbol.usr)
    }

    /// Whether the store records the declaration `row` as inheriting from `base` through any chain of clauses (``inherits(_:from:)``): `false` where the row resolves to no symbol the store holds.
    func inherits(_ row: SymbolRow, from base: String) -> Bool {
        usr(for: row).map { inherits($0, from: base) } ?? false
    }

    /// Whether the store records the declaration `row`, or the type it extends where it is an extension, as inheriting from `base` through any chain of clauses: the type the compiler resolved the extension to, never another type of its name.
    func inheritsThroughExtendedType(_ row: SymbolRow, from base: String) -> Bool {
        inherits(row, from: base) || row.kind == .extensionKind && extendedTypes(of: row).contains { inherits($0, from: base) }
    }

    /// The types the extension `row` extends as the store resolved it: each type of its name the store records as extended at the row's header, in the row's file.
    ///
    /// The store holds no canonical occurrence of an extension by its name, so the extension is found from the type's side, by the header the store records extending it.
    private func extendedTypes(of row: SymbolRow) -> [String] {
        guard answers(forFile: row.path) else { return [] }
        let lines = row.line ... max(row.line, row.endLine)
        let spellings = Set(Self.spellings(ofFile: row.path, under: repoRoot))
        return Set(canonicalOccurrences(ofName: Self.asTheStoreSpellsIt(DeclaredTypeName.last(ofPath: row.name))).map(\.symbol.usr)).filter { usr in
            occurrences(ofUSR: usr, roles: .extendedBy).contains { occurrence in
                spellings.contains(occurrence.location.path) && lines.contains(occurrence.location.line)
            }
        }.sorted()
    }

    /// Whether the store records a declaration named `name` written where `hit` starts: the name a clause wrote there when the store was built, which still tells what that clause wrote once its file is edited and the store's line and column no longer place it.
    ///
    /// Only a reference that is no base counts: a clause writing a typealias of a composition is recorded as conforming to each of its members at the alias's token, and none of those is the name written there.
    func records(_ name: String, writtenAt hit: Hit) -> Bool {
        Set(canonicalOccurrences(ofName: Self.asTheStoreSpellsIt(name)).map(\.symbol.usr)).contains { usr in
            occurrences(ofUSR: usr, roles: .reference).contains { occurrence in
                !occurrence.roles.contains(.baseOf) && occurrence.location.path == hit.path && occurrence.location.line == hit.line && occurrence.location.utf8Column == hit.column
            }
        }
    }

    /// Whether the store records `usr` as inheriting from `base` through any chain of clauses, each written as an occurrence of the base with `baseOf` relating it to the inheritor, or to an extension of it where the extension declares the conformance.
    private func inherits(_ usr: String, from base: String) -> Bool {
        var seen: Set<String> = [usr]
        var pending = [usr]
        while let inheritor = pending.popLast() {
            let extensions = occurrences(ofUSR: inheritor, roles: .extendedBy).flatMap { occurrence in
                occurrence.relations.filter { $0.roles.contains(.extendedBy) }.map(\.symbol.usr)
            }
            let bases = ([inheritor] + extensions).flatMap { declaration in
                occurrences(relatedToUSR: declaration, roles: .baseOf).filter { occurrence in
                    occurrence.relations.contains { $0.symbol.usr == declaration && $0.roles.contains(.baseOf) }
                }
            }
            for occurrence in bases {
                if occurrence.symbol.usr == base {
                    return true
                }
                if seen.insert(occurrence.symbol.usr).inserted {
                    pending.append(occurrence.symbol.usr)
                }
            }
        }
        return false
    }

    /// Where the type `usr` names is extended — one hit at each `extension` header, which is the only thing that tells the type's own extensions from another type's spelled with the same name.
    ///
    /// The store writes an extension as an occurrence *of the extended type* at the header, with the extension in the relation (`ref|extendedBy`, relation `Widget:extension:[extendedBy]` — verified empirically against a real store, on a two-module fixture where one module's `extension Widget` over its *own* `Widget` carried that module's USR and never the other's, and `extension Outer.Item` carried the nested type's and never the top-level `Item`'s). So the USR settles identity where the written name cannot: a leaf name repeats across modules, and a nested type's name ends in one.
    ///
    /// Where an extension *ends* is not recorded here — the store anchors a header, not a range — so a caller that needs the span reads it off the syntactic row the header line falls inside (``WhereRenderer/ownSpans(of:extendedAt:relativePath:)``).
    func extensionSites(ofUSR usr: String) -> [Hit] {
        Self.written(occurrences(ofUSR: usr, roles: .extendedBy)).map { kept in
            Hit(kept.occurrence, name: relatedName(of: kept.occurrence, by: .extendedBy) ?? "(unknown)")
        }
    }
}

/// The rules every relation above is read by: which occurrences stand for code, and how a hit names the declaration it sits in.
private extension SemanticStore {
    /// An occurrence kept as written in code, and — for one the store relates to no declaration — the freestanding macro whose argument it is written in, read off the expansion's copy of it: `(inside #Preview)`.
    struct Written {
        let occurrence: SymbolOccurrence
        var enclosure: String?
    }

    /// The occurrences written in code: an implicit occurrence in a declaration is dropped as a macro expansion's copy where the same unit also recorded the same symbol written in the same declaration, or, when the copy sits in a declaration the expansion generated (``ExpansionOrigin/isGenerated(_:)``), written in no declaration at all, in the same file at or after the copy's line.
    ///
    /// Verified empirically against a real store: `#expect(f() == 1)` records the call to `f()` where it is written and again, implicit, at the `#expect` — on the line the macro opens, so a call written on the line after it was listed on both. `#Preview { Counter(model: Model()) }` records `Model()` on the line it is written with no relation at all — the closure is an argument to a macro at file scope — and again, implicit, at the `#Preview` line inside the `makePreview()` the expansion generates: two calls were listed as three, the extra under a generated name and the real one as an unknown caller. A copy is matched to the nearest written one at or after its line, and that one is named by the macro it is written in. An implicit occurrence with no written twin stays, because some uses are only ever implicit: a property wrapper's `init(wrappedValue:)` is called at `@Clamp var amount = 3` and nowhere else, a dynamic-member subscript is read at `box.level`, and `@Test` calls the function it is attached to from a function it generates — dropping those would answer "no callers" of something in use. A declaration that makes one call both ways keeps its written row.
    ///
    /// An implicit occurrence in no declaration has no "same declaration" to share, so it is never taken for the copy of another written in none: a subclass written through its base's own typealias, recorded on the base as an implicit occurrence at the clause, is no copy of the clause another type writes beside it in the file, and neither is the conformance a macro's extension adds, nor a reference at file scope beside an unrelated one. The implicit record at an alias's clause is a second record of the site the alias's own reference stands for, and `where` sets it aside where it merges the two (``WhereRenderer/AliasFold/ownReferences(_:)``).
    static func written(_ occurrences: [SymbolOccurrence]) -> [Written] {
        let written = occurrences.filter { !$0.roles.contains(.implicit) }
        let twins = Set(written.map(Twin.init))
        let unrelated = Dictionary(grouping: written.filter { container(of: $0) == nil }, by: Place.init)
        var copies: [Place: [(line: Int, enclosure: String)]] = [:]
        var kept: [SymbolOccurrence] = []
        for occurrence in occurrences {
            guard occurrence.roles.contains(.implicit) else {
                kept.append(occurrence)
                continue
            }
            if container(of: occurrence) != nil, twins.contains(Twin(occurrence)) {
                continue
            }
            let place = Place(occurrence)
            if let expansion = container(of: occurrence)?.usr, let origin = ExpansionOrigin(mangled: expansion),
               unrelated[place]?.contains(where: { $0.location.line >= occurrence.location.line }) == true
            {
                copies[place, default: []].append((occurrence.location.line, "(inside \(origin.spelling))"))
                continue
            }
            kept.append(occurrence)
        }
        return kept.map { occurrence in
            guard !occurrence.roles.contains(.implicit), container(of: occurrence) == nil else { return Written(occurrence: occurrence) }
            let nearest = copies[Place(occurrence)]?.filter { $0.line <= occurrence.location.line }.max { $0.line < $1.line }
            return Written(occurrence: occurrence, enclosure: nearest?.enclosure)
        }
    }

    /// Whether an occurrence is a mention a macro generated: an implicit reference that neither calls, reads nor writes, inside a declaration the store records as implicit — `implicitDeclarations` caches that answer by the declaration's USR for one query.
    ///
    /// Verified empirically against a real store: `@Observable` declares `_feed` beside `var feed: Feed`, and the store records the storage's type as an implicit reference to `Feed` at the `@Observable` attribute, inside `_feed`, whose definition it marks implicit; the observation accessors it adds name the class there the same way. So a line holding only the attribute was listed as a reference and counted as a production use. Only a plain mention is taken: a call, read or write in generated code can be the only record of a real use — `@Test`'s call to the function it is attached to, a wrapper's `init(wrappedValue:)` — and a mention written on the attribute's line, `@Observable final class Relay: Feed`, is no implicit occurrence, so it stays.
    func isGeneratedMention(_ occurrence: SymbolOccurrence, implicitDeclarations: inout [String: Bool]) -> Bool {
        guard occurrence.roles.contains(.implicit), occurrence.roles.isDisjoint(with: [.call, .read, .write]),
              let container = Self.container(of: occurrence)?.usr
        else { return false }
        if let known = implicitDeclarations[container] {
            return known
        }
        let implicit = occurrences(ofUSR: container, roles: .definition).contains { $0.roles.contains(.implicit) }
        implicitDeclarations[container] = implicit
        return implicit
    }

    /// The declaration the store records an occurrence inside, `nil` for one it relates to none.
    static func container(of occurrence: SymbolOccurrence) -> Symbol? {
        occurrence.relations.first { $0.roles.contains(.containedBy) }?.symbol
    }

    /// What an expansion's copy of an occurrence shares with it: the symbol, the declaration containing it, and the unit.
    struct Twin: Hashable {
        let usr: String
        let container: String?
        let unit: String

        init(_ occurrence: SymbolOccurrence) {
            usr = occurrence.symbol.usr
            container = SemanticStore.container(of: occurrence)?.usr
            unit = Hit.unit(of: occurrence)
        }
    }

    /// Where one build unit recorded an occurrence of a symbol: what tells a site listed twice from two units' records of one.
    struct Anchor: Hashable {
        let usr: String
        let unit: String
        let path: String
        let line: Int
        let column: Int

        init(_ occurrence: SymbolOccurrence) {
            usr = occurrence.symbol.usr
            unit = Hit.unit(of: occurrence)
            path = occurrence.location.path
            line = occurrence.location.line
            column = occurrence.location.utf8Column
        }
    }

    /// What a freestanding macro's copy of an occurrence shares with the one written in its argument, which the store relates to nothing: the symbol, the unit, and the file.
    struct Place: Hashable {
        let usr: String
        let unit: String
        let path: String

        init(_ occurrence: SymbolOccurrence) {
            usr = occurrence.symbol.usr
            unit = Hit.unit(of: occurrence)
            path = occurrence.location.path
        }
    }

    /// A property as its uses and references are read: the USRs whose occurrences are its uses, and its name, which tells an observer a macro moved from any other declaration.
    struct Property {
        let usr: String
        /// The property's name — `nil` for a declaration that is not a property.
        let name: String?
        let siblings: [Target]
        /// Whether the store records something written in the property's attributes — a wrapper's type, as `@Clamp` is — which a property must have before any use of it can be spelled through a sibling.
        let wrapped: Bool

        /// The sibling a use the store records on the property itself is written through — `_amount`, `$stored` — read off the line it is on (``SourceLines/sibling(spelling:of:)``); `nil` for a use spelled by the property's own name, and for every use of a property with no attributes, whose lines are then never read.
        func sibling(spelling occurrence: SymbolOccurrence, in sources: inout SourceLines) -> String? {
            guard wrapped, let name else { return nil }
            return sources.sibling(spelling: occurrence, of: name)
        }

        /// The property's own USR first, then its siblings'.
        var targets: [Target] {
            [Target(usr: usr, through: nil)] + siblings
        }

        /// Whether an occurrence is an implicit use inside an accessor of the property or of either sibling — generated code, with nothing written at its line (``SemanticStore/isInsideOwnAccessor(_:of:)``) — other than an observer a macro moved there, which holds what the property's `didSet` or `willSet` says (``movedObserver(containing:)``).
        ///
        /// The siblings' accessors count because the compiler writes them as well. Verified empirically against a real store: an internal or public `@State var on` gets a `$on` whose getter reads `_on`, recorded as an implicit read of `_on` at the declaration, inside `getter:$on` — so a property nothing uses was listed as read through its own storage, and a used one carried that row beside its real ones. A `private` one records no `$on` at all, which is why only the wider access showed it.
        func isGenerated(_ occurrence: SymbolOccurrence) -> Bool {
            occurrence.roles.contains(.implicit) && movedObserver(containing: occurrence) == nil
                && targets.contains { SemanticStore.isInsideOwnAccessor(occurrence, of: $0.usr) }
        }

        /// The name a use inside a `didSet` or `willSet` a macro moved into generated storage is listed by — `didSet of watched (moved by a macro)` — `nil` for any other use.
        ///
        /// Verified empirically against a real store: `@Observable` moves a property's observer onto the storage it generates, `_watched`, and the store records every use inside it as implicit, at the `@Observable` attribute, in a declaration named `didSet:_watched` — the line the observer is written on has no occurrence at all.
        func movedObserver(containing occurrence: SymbolOccurrence) -> String? {
            guard let name, occurrence.roles.contains(.implicit), let container = SemanticStore.container(of: occurrence)?.name else { return nil }
            return ["didSet", "willSet"].first { container == "\($0):_\(name)" }.map { "\($0) of \(name) (moved by a macro)" }
        }
    }

    /// `usr` read as a property, for the rules its uses and references are read by: its name, and the siblings a property wrapper declares beside it — `$flag`, its projected value, and `_flag`, its storage.
    ///
    /// Verified empirically against a real store: `@State private var flag` used only in `Toggle("f", isOn: $flag)` records that read on `$flag`'s own USR and nothing on `flag`'s, and `_count = State(initialValue: 3)` records a write on `_count`'s; each sibling is an implicit declaration the store records beside the property, a child of the same type. An `@AppStorage`, a `@FocusState` and a wrapper declared in the property's own module declare no sibling the store records: `$stored`, `$focused`, `_amount` and `$amount` are recorded on the property itself, which is why a use is also read for how it is spelled (``Property/sibling(spelling:in:)``).
    ///
    /// **What the lookup checks**, and no more: a declaration named `$name` or `_name` that the store marks implicit and records as a child of the property's own parent. So a `_name` written in code beside `name` is a declaration of its own and never one of these, however it is used — it is not implicit. Where each sibling sits is not checked. `@Observable` declares an implicit `_level` beside `level` too, every use of which sits inside `level`'s own accessors, so none of it is listed. A USR that is not a property's — `vp`, or `vpZ` for a static one — has no siblings, and is not looked up.
    func property(ofUSR usr: String) -> Property {
        guard usr.hasSuffix("vp") || usr.hasSuffix("vpZ"),
              let definition = occurrences(ofUSR: usr, roles: .definition).first
        else {
            return Property(usr: usr, name: nil, siblings: [], wrapped: false)
        }
        let name = definition.symbol.name
        let parent = Self.parent(of: definition)
        let siblings = ["$" + name, "_" + name].compactMap { spelled in
            canonicalOccurrences(ofName: spelled)
                .first { $0.roles.contains(.implicit) && Self.parent(of: $0) == parent }
                .map { Property.Target(usr: $0.symbol.usr, through: spelled) }
        }
        // An attribute is written before the name it is attached to, and the store records the wrapper type it names as an occurrence the property contains — `@Clamp` at its own column.
        let wrapped = occurrences(relatedToUSR: usr, roles: .containedBy).contains { occurrence in
            occurrence.location.path == definition.location.path
                && (occurrence.location.line, occurrence.location.utf8Column) < (definition.location.line, definition.location.utf8Column)
        }
        return Property(usr: usr, name: name, siblings: siblings, wrapped: wrapped)
    }
}

extension SemanticStore {
    /// Source lines read from disk once per file, for the one thing the store's record of a use leaves out: how it is spelled.
    ///
    /// Held for one query and no longer (`WhereRenderer` makes one per `where`): a use file edited since the build is read as it stands at that query, never as an earlier query found it.
    struct SourceLines {
        private var files: [String: [ArraySlice<UInt8>]] = [:]

        /// The wrapper sibling an occurrence of the property named `name` is written through — `_amount`, `$stored` — `nil` for one written as the name itself, or on a line that no longer holds the name at the occurrence's column.
        ///
        /// Verified empirically against a real store: a use the store records on the property itself through its sibling sits at the column of the property's name *inside* the sibling's — one byte past the `_` or `$` — and is recorded as a read whatever it does: `_amount = Clamp(wrappedValue: 0)`, `_item.wrappedValue += 1`, `$item = 2` through a settable projection, and `Stepper(value: $stored)` alike. So the byte before the name tells the spelling, and nothing the store holds tells a write from a read there.
        mutating func sibling(spelling occurrence: SymbolOccurrence, of name: String) -> String? {
            guard let line = line(occurrence.location.line, of: occurrence.location.path) else { return nil }
            let start = line.startIndex + occurrence.location.utf8Column - 1
            let end = start + name.utf8.count
            guard start > line.startIndex, end <= line.endIndex, line[start ..< end].elementsEqual(name.utf8) else { return nil }
            let sigil = line[start - 1]
            guard sigil == UInt8(ascii: "_") || sigil == UInt8(ascii: "$") else { return nil }
            // The sigil opens the word and the name closes it: `x_amount` and `_amounts` are names of their own.
            if start - 1 > line.startIndex, Self.isIdentifierByte(line[start - 2]) {
                return nil
            }
            if end < line.endIndex, Self.isIdentifierByte(line[end]) {
                return nil
            }
            return String(Unicode.Scalar(sigil)) + name
        }

        /// Line `number` of the file at `path`, `nil` where the file or the line is gone.
        private mutating func line(_ number: Int, of path: String) -> ArraySlice<UInt8>? {
            if files[path] == nil {
                let bytes = FileManager.default.contents(atPath: path).map { [UInt8]($0) } ?? []
                files[path] = bytes.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            }
            guard let lines = files[path], lines.indices.contains(number - 1) else { return nil }
            return lines[number - 1]
        }

        /// A byte an identifier can hold — every byte of a non-ASCII character among them.
        private static func isIdentifierByte(_ byte: UInt8) -> Bool {
            byte >= 0x80 || byte == UInt8(ascii: "_")
                || (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains(byte)
        }
    }
}

extension SemanticStore {
    /// How many references to `usr` (and to a property's wrapper siblings) ``fromCurrentUnits(_:)`` sets aside, by the absolute path of the file they sit in and then their line: sites only a unit older than their file's last edit records, which an answer must say it left out.
    func setAsideReferences(ofUSR usr: String) -> [String: [Int: Int]] {
        var counts: [String: [Int: Int]] = [:]
        for target in property(ofUSR: usr).targets {
            let recorded = database.occurrences(ofUSR: target.usr, roles: .reference)
            for occurrence in recorded {
                counts[occurrence.location.path, default: [:]][occurrence.location.line, default: 0] += 1
            }
            for occurrence in fromCurrentUnits(recorded) {
                counts[occurrence.location.path, default: [:]][occurrence.location.line, default: 0] -= 1
            }
        }
        return counts.compactMapValues { lines in
            let kept = lines.filter { $0.value > 0 }
            return kept.isEmpty ? nil : kept
        }
    }
}

private extension SemanticStore {
    /// The occurrences of `usr` carrying any of `roles`, each read from a unit that describes its file as it stands (``fromCurrentUnits(_:)``): every occurrence read goes through here or ``occurrences(relatedToUSR:roles:)``, never straight to the database.
    func occurrences(ofUSR usr: String, roles: SymbolRole) -> [SymbolOccurrence] {
        fromCurrentUnits(database.occurrences(ofUSR: usr, roles: roles))
    }

    /// The occurrences related to `usr` by any of `roles`, read from current units as ``occurrences(ofUSR:roles:)`` reads them.
    func occurrences(relatedToUSR usr: String, roles: SymbolRole) -> [SymbolOccurrence] {
        fromCurrentUnits(database.occurrences(relatedToUSR: usr, roles: roles))
    }

    /// The occurrences recorded by a unit that describes its file as the file now stands: one no older than the earlier of the file's newest unit and its last change.
    ///
    /// A store keeps one unit per output file, so a source compiled for two architectures, platforms or configurations has a unit for each, and IndexStoreDB answers from all of them. One that no build has replaced since the file changed still records the file's old content: verified against a real Xcode store, where a simulator build for one architecture a fortnight old sat beside today's build for the other, and listed a caller at the line its call had held before the file was edited, credited to the function now there. A unit written after the file's last change describes the file as it stands, so every configuration built since the edit answers together and a call only one of them compiles is still listed; where none was, the file's newest unit alone answers, which is the store-wide approximation the staleness anchor already makes. The change moment is the later of mtime and ctime (``FileChangeStat``), since a restored mtime cannot move ctime back; a file that cannot be statted is read from its newest unit.
    func fromCurrentUnits(_ occurrences: [SymbolOccurrence]) -> [SymbolOccurrence] {
        var floors: [String: Date] = [:]
        return occurrences.filter { occurrence in
            let path = occurrence.location.path
            let floor = floors[path] ?? currentUnitFloor(ofFile: path)
            floors[path] = floor
            return occurrence.location.timestamp >= floor
        }
    }

    /// The canonical occurrences of a symbol named `name`, each from a unit that describes its file as it stands (``fromCurrentUnits(_:)``).
    ///
    /// IndexStoreDB returns the definition from every unit that recorded it, so a unit older than the file's last edit hands back its own copy beside the current one. The current provider is always among those returned, since a file's newest unit clears its own floor, so filtering never hides a symbol a current unit holds.
    func canonicalOccurrences(ofName name: String) -> [SymbolOccurrence] {
        fromCurrentUnits(database.canonicalOccurrences(ofName: name))
    }

    /// The oldest moment a unit of the file at `path` can have been written at and still describe it: the earlier of its newest unit and its last change; `distantPast` for a file the store holds no unit for.
    func currentUnitFloor(ofFile path: String) -> Date {
        guard let newest = newestUnit(ofFile: path) else { return .distantPast }
        guard let changed = FileChangeStat.of(path: path)?.changed else { return newest }
        return min(newest, Date(timeIntervalSince1970: changed))
    }

    /// The declaration a definition is a child of, `nil` for a top-level one.
    static func parent(of definition: SymbolOccurrence) -> String? {
        definition.relations.first { $0.roles.contains(.childOf) }?.symbol.usr
    }

    /// Whether the declaration containing an occurrence is one of the accessors of the property or subscript `usr` names.
    ///
    /// An accessor's USR is its declaration's with one letter changed, verified empirically against a real store on an `@Observable` class's properties and a static computed property: the pseudo-accessor `p` that stands for the declaration itself, last in the USR or just before the `Z` a static member's ends in, becomes the accessor's own — `g` for the getter, `s` the setter, `M` the modify coroutine. Matched on the USR because the store relates only some of them to the property: the getter and setter are `getter:level` and `setter:level`, each related to the property as its accessor, the modify coroutine a declaration with an empty name and no such relation.
    static func isInsideOwnAccessor(_ occurrence: SymbolOccurrence, of usr: String) -> Bool {
        guard let container = occurrence.relations.first(where: { $0.roles.contains(.containedBy) })?.symbol.usr else { return false }
        let declaration = Array(usr.utf8)
        let candidate = Array(container.utf8)
        let marker = declaration.last == UInt8(ascii: "Z") ? declaration.count - 2 : declaration.count - 1
        guard marker > 0, candidate.count == declaration.count, declaration[marker] == UInt8(ascii: "p") else { return false }
        return candidate[marker] != UInt8(ascii: "p")
            && candidate[..<marker] == declaration[..<marker]
            && candidate[(marker + 1)...] == declaration[(marker + 1)...]
    }

    /// The name of the declaration a kept occurrence is related to by any of `roles` — or, for one written in a macro's argument, what encloses it — `nil` when there is neither.
    func name(of kept: Written, by roles: SymbolRole) -> String? {
        relatedName(of: kept.occurrence, by: roles) ?? kept.enclosure
    }

    /// The name of the declaration an occurrence is related to by any of `roles`, `nil` when there is none.
    func relatedName(of occurrence: SymbolOccurrence, by roles: SymbolRole) -> String? {
        occurrence.relations.first { !$0.roles.isDisjoint(with: roles) }.map { displayName(of: $0.symbol) }
    }

    /// A declaration's name as a reader can use it: one a macro's expansion declared under a mangled name, as `@Test` names the function it generates, by the macro that made it, `(@Test expansion of spans)`, as the runtime's demangler reads it (``ExpansionOrigin``) — the store's own name where the demangler cannot, never a name it did not confirm; one the store leaves empty, as it does a modify coroutine, by what it is and whose (``accessorName(of:)``) — never a blank, which reads as a field the answer forgot to fill.
    func displayName(of symbol: Symbol) -> String {
        if symbol.name.hasPrefix("$"), let origin = ExpansionOrigin(mangled: symbol.name) {
            return "(\(origin.expansion))"
        }
        guard symbol.name.isEmpty else { return symbol.name }
        return accessorName(of: symbol) ?? "(unnamed \(symbol.kind))"
    }

    /// An accessor the store names with an empty string, named by its kind and its property — `modify accessor of total` — or `nil` where the store relates it to no declaration.
    ///
    /// Verified empirically against a real store: a `_modify` coroutine's USR is its property's with the last letter (before a static member's `Z`) `M` where the property's is `p`, and its definition is recorded as a child of the property, which names it.
    func accessorName(of symbol: Symbol) -> String? {
        let owners = occurrences(ofUSR: symbol.usr, roles: .definition).compactMap { definition in
            definition.relations.first { $0.roles.contains(.childOf) }?.symbol.name
        }
        guard let owner = owners.first(where: { !$0.isEmpty }) else { return nil }
        let letters = symbol.usr.utf8
        let letter = letters.last == UInt8(ascii: "Z") ? letters.dropLast().last : letters.last
        let kind = switch letter {
        case UInt8(ascii: "M"): "modify accessor"
        case UInt8(ascii: "r"): "read accessor"
        default: "accessor"
        }
        return "\(kind) of \(owner)"
    }
}

private extension SemanticStore.Property {
    /// A USR whose occurrences are uses of the property, and the sibling it spells — `nil` for the property's own.
    struct Target {
        let usr: String
        let through: String?
    }
}

/// A hit read off an occurrence: where it is, the declaration it is credited to, the unit that recorded it, and the wrapper's sibling it went through.
private extension SemanticStore.Hit {
    init(_ occurrence: SymbolOccurrence, name: String, through: String? = nil) {
        self.init(
            name: name,
            path: occurrence.location.path,
            line: occurrence.location.line,
            column: occurrence.location.utf8Column,
            unit: Self.unit(of: occurrence),
            through: through
        )
    }

    /// The unit that recorded an occurrence, as IndexStoreDB reports it on each copy it hands back — the module the unit compiled and when the unit was written, all a copy carries that tells one unit's from another's.
    static func unit(of occurrence: SymbolOccurrence) -> String {
        "\(occurrence.location.moduleName) \(occurrence.location.timestamp.timeIntervalSince1970)"
    }
}

extension SemanticStore {
    /// One semantic answer row: a related symbol and where it is.
    struct Hit {
        let name: String
        let path: String
        let line: Int
        /// The UTF-8 column the occurrence starts at, 1-based, which tells two occurrences on one line apart; 0 for a hit made by hand.
        var column = 0
        /// The build unit that recorded the hit — the module it compiled and when it was written — which is what tells one site two units both recorded from two sites one unit recorded on one line (``WhereRenderer/collapsedIdentical(_:)``).
        ///
        /// Empty for a hit made by hand, which counts as one unit.
        var unit = ""
        /// The property wrapper's sibling a property's use or reference went through — `$flag`, `_count` — `nil` for one of the declaration itself.
        var through: String?
        /// For a conformance to, or subclass of, another protocol or class of the asked one's name, the path of that type's declaration; `nil` otherwise.
        var protocolPath: String?
        /// The typealias this hit is written as, for a reference the store recorded against an alias of the symbol the answer is about — `nil` for one written as the symbol's own name.
        ///
        /// Kept apart from ``through`` rather than folded into it: a sibling spelling is a line a *rename* must edit, and the headings that name siblings say so, where an alias spelling is a line a rename of this type leaves alone and only a deletion cares about. One field for both would put alias names in a rename's heading.
        var writtenAs: String?
        /// Whether a caller names the symbol without calling it — a function handed on unapplied, or named in a `#selector`.
        var uncalled = false
    }

    /// One use of a property, a subscript or an enum case: where it is and what it is in, and which access the store recorded there — neither for an enum case, which is never read or written, nor for a property only named, as an argument to its memberwise initializer names it.
    struct Use {
        let hit: Hit
        let reads: Bool
        let writes: Bool
        /// Whether the use sits in a `didSet` or `willSet` a macro moved into generated storage, which the store records at the macro rather than where it is written.
        var inMovedObserver = false
        /// Whether `reads` and `writes` say what the use does: `false` for one written through a wrapper's `$` or `_` sibling that the store records on the property itself, as a read whatever it does — `_amount = Clamp(wrappedValue: 0)` included.
        var accessRecorded = true
    }

    /// An open whose store was replaced while it read: what it read is another store's, and its cache is gone with it.
    struct ReplacedWhileRead: Error, CustomStringConvertible {
        var description: String {
            "the index store was replaced while it was read"
        }
    }
}
