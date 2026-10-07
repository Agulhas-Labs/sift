//
// Copyright © Agulhas Labs
//

import Foundation

/// The typed persistence layer: schema lifecycle, delete-then-insert file replacement, and every query the renderers need.
///
/// A schema-version mismatch drops every table in place and rebuilds — the source of truth is the source code, and migration logic for a derived cache is pure cost (Docs/Design.md §6.6). The tables rather than the file, for the reason `init` gives.
///
/// Concurrency contract: a store is owned by one engine and accessed serially (see `SiftEngine`); the SQLite connection is never shared across concurrent in-process tasks.
public final class IndexStore: @unchecked Sendable {
    private let database: SQLiteDatabase
    private let databasePath: String
    /// Device + inode of the file this connection was opened on, so a store that has been deleted or replaced underneath a long-lived process can be recognized rather than answered from.
    private var backingFileIdentity: FileIdentity?

    /// The path that opens a store in memory only — a transient index discarded with its connection, never written to disk.
    static var inMemoryPath: String {
        ":memory:"
    }

    public init(databasePath: String) throws {
        self.databasePath = databasePath
        if databasePath != Self.inMemoryPath {
            let directory = (databasePath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }

        let opened = try SQLiteDatabase(path: databasePath)
        var storedVersion: Int32 = 0
        // The read statement must be reset before any journal-mode pragma: an un-reset SELECT holds an implicit read transaction, and WAL cannot be entered inside one.
        do {
            let versionStatement = try opened.prepare(PragmaStatement.userVersionRead.sql)
            if try versionStatement.step() {
                storedVersion = Int32(versionStatement.columnInt(0))
            }
            versionStatement.reset()
        }
        database = opened
        if storedVersion != 0, storedVersion != IndexSchema.version {
            // Drop in place rather than deleting files: another process may hold the database open, and unlinking a live SQLite file is a documented corruption path.
            for statement in IndexSchema.dropStatements {
                try database.execute(statement)
            }
            storedVersion = 0
        }
        if storedVersion == 0 {
            for pragma in IndexSchema.preCreationPragmas {
                try database.execute(pragma)
            }
            // Creation is transactional and every statement idempotent (IF NOT EXISTS): a crash mid-init leaves either nothing or everything, and a process racing the first create loses cleanly instead of erroring on a half-made schema.
            try database.inTransaction {
                for statement in IndexSchema.createStatements {
                    try database.execute(statement)
                }
                try database.execute(PragmaStatement.userVersionWrite(IndexSchema.version).sql)
            }
        } else {
            try database.execute(PragmaStatement.journalSizeLimit.sql)
        }
        backingFileIdentity = FileIdentity(path: databasePath)
    }

    /// Whether this connection still refers to the file at its own path.
    ///
    /// SQLite keeps answering from an unlinked inode until it needs the disk, and then fails with `SQLITE_IOERR` forever — so a `.sift/` wiped by a `git clean`, or a worktree removed and recreated at the same path, poisons a cached store permanently. The identity is device + inode rather than mere existence, because a replaced file is as dead to this handle as a deleted one.
    public var isBackingFileIntact: Bool {
        guard let backingFileIdentity else { return true }
        return FileIdentity(path: databasePath) == backingFileIdentity
    }

    // MARK: Meta

    public func metaValue(_ key: String) throws -> String? {
        let statement = try database.prepare(StoreStatement.metaGet.sql)
        statement.bind(1, key)
        guard try statement.step() else { return nil }
        return statement.columnText(0)
    }

    public func setMetaValue(_ value: String, forKey key: String) throws {
        let statement = try database.prepare(StoreStatement.metaSet.sql)
        statement.bind(1, key).bind(2, value)
        try statement.run()
    }

    // MARK: Writes

    /// Replaces the given files' rows wholesale — delete-then-insert inside batched transactions, keyed on path (Docs/Design.md §6.1).
    public func replaceFiles(_ files: [ParsedFile], moduleFor: (String) -> (module: String, guessed: Bool)) throws {
        let batchSize = 100
        var start = 0
        while start < files.count {
            let end = min(start + batchSize, files.count)
            try database.inTransaction {
                for file in files[start ..< end] {
                    try deleteFileRow(path: file.path)
                    let resolution = moduleFor(file.path)
                    try insertFile(file, module: resolution.module, guessed: resolution.guessed)
                }
            }
            start = end
        }
    }

    /// Rewrites every file row's module attribution from the current resolver — a path→module recompute, no reparse; returns how many rows changed.
    ///
    /// Exists because module attribution depends on inputs *outside* the file it is stored with — the manifest, the XcodeGen files, the `moduleMap`, and the resolver's own logic. Content-keyed invalidation can never see those change, so the engine calls this whenever the resolution fingerprint moves.
    public func reattributeModules(moduleFor: (String) -> (module: String, guessed: Bool)) throws -> Int {
        let inventory = try fileInventory()
        var changed = 0
        try database.inTransaction {
            let update = try database.prepare(StoreStatement.reattributeUpdate.sql)
            for (path, row) in inventory.sorted(by: { $0.key < $1.key }) {
                let resolution = moduleFor(path)
                guard resolution.module != row.module || resolution.guessed != row.moduleGuessed else { continue }
                update
                    .bind(1, resolution.module)
                    .bind(2, Int64(resolution.guessed ? 1 : 0))
                    .bind(3, row.id)
                try update.run()
                update.reset()
                changed += 1
            }
        }
        return changed
    }

    /// Removes the rows for paths that no longer exist; FTS rows first, then the file row (cascade takes symbols and inheritance).
    ///
    /// Every path that actually had rows AND is missing at the moment it is dropped is written to the ``DeletionLedger`` in the same transaction, at `instant`: this is the one place every route to a deletion passes through — a query's dirty set, a head move, `reconcile`, a full rebuild — and the rows it drops are the only evidence `status` could otherwise have had that the file was ever here.
    ///
    /// `stillOnDisk` is what keeps a drop that is not a deletion out of the ledger: a row can be dropped from the store for a reason that leaves the file exactly where it was — narrowed away by a fresher `.sift.json`, gitignored since the last build — and recording those crowds the bounded ledger with entries a real deletion never produced, which is exactly what lets the capacity's eviction (``DeletionLedger/record(_:at:)``) forget a file that is genuinely gone. The default records everything, for a caller with no file-system view of its own to ask.
    public func deleteFiles(paths: [String], at instant: Date = Date(), stillOnDisk: (String) -> Bool = { _ in false }) throws {
        guard !paths.isEmpty else { return }
        try database.inTransaction {
            var dropped: [String] = []
            for path in paths {
                guard try deleteFileRow(path: path) else { continue }
                dropped.append(path)
            }
            let deleted = dropped.filter { !stillOnDisk($0) }
            guard !deleted.isEmpty else { return }
            var ledger = try deletionLedger()
            ledger.record(deleted, at: instant.timeIntervalSince1970)
            try setMetaValue(ledger.metaValue, forKey: DeletionLedger.metaKey)
        }
    }

    /// Deletes one file's rows; `false` when the path had none.
    @discardableResult
    private func deleteFileRow(path: String) throws -> Bool {
        let lookup = try database.prepare(StoreStatement.deleteFileLookup.sql)
        lookup.bind(1, path)
        guard try lookup.step() else { return false }
        let fileID = lookup.columnInt(0)
        let ftsDelete = try database.prepare(StoreStatement.deleteFtsRows.sql)
        ftsDelete.bind(1, fileID)
        try ftsDelete.run()
        let fileDelete = try database.prepare(StoreStatement.deleteFileRow.sql)
        fileDelete.bind(1, fileID)
        try fileDelete.run()
        return true
    }

    private func insertFile(_ file: ParsedFile, module: String, guessed: Bool) throws {
        let fileInsert = try database.prepare(StoreStatement.insertFile.sql)
        fileInsert
            .bind(1, file.path)
            .bind(2, file.mtime)
            .bind(3, Int64(file.size))
            .bind(4, file.contentHash)
            .bind(5, module)
            .bind(6, Int64(guessed ? 1 : 0))
            .bind(7, file.imports.joined(separator: " "))
            .bind(8, Int64(file.parseErrorCount))
        try fileInsert.run()
        let fileID = database.lastInsertRowID

        let symbolInsert = try database.prepare(StoreStatement.insertSymbol.sql)
        let inheritedInsert = try database.prepare(StoreStatement.insertInherited.sql)
        let ftsInsert = try database.prepare(StoreStatement.insertFtsSymbol.sql)

        var rowIDForIndex: [Int64] = []
        rowIDForIndex.reserveCapacity(file.symbols.count)
        for symbol in file.symbols {
            symbolInsert.bind(1, fileID)
            if let parentIndex = symbol.parentIndex {
                symbolInsert.bind(2, rowIDForIndex[parentIndex])
            } else {
                symbolInsert.bindNull(2)
            }
            symbolInsert
                .bind(3, symbol.kind.rawValue)
                .bind(4, symbol.name)
                .bind(5, Int64(symbol.line))
                .bind(6, Int64(symbol.column))
                .bind(7, Int64(symbol.endLine))
                .bind(8, symbol.accessLevel.rawValue)
                .bind(9, Int64(symbol.isStatic ? 1 : 0))
                .bind(10, Int64(symbol.isStored ? 1 : 0))
                .bind(11, symbol.signature)
                .bindOptional(12, symbol.docSummary)
                .bindOptional(13, symbol.ifConfigCondition)
                .bindOptional(14, symbol.viewOutline)
            try symbolInsert.run()
            symbolInsert.reset()
            let symbolID = database.lastInsertRowID
            rowIDForIndex.append(symbolID)

            for (position, inheritedName) in symbol.inherited.enumerated() {
                inheritedInsert.bind(1, symbolID).bind(2, inheritedName).bind(3, Int64(position))
                try inheritedInsert.run()
                inheritedInsert.reset()
            }
            ftsInsert.bind(1, symbolID).bind(2, symbol.name)
            try ftsInsert.run()
            ftsInsert.reset()
        }
    }

    // MARK: Maintenance

    /// Reclaims pages and FTS tombstones after bulk deletes (Docs/Design.md §6.5).
    public func compact() throws {
        try database.execute(StoreStatement.ftsOptimize.sql)
        try database.execute(PragmaStatement.incrementalVacuum.sql)
        try database.execute(PragmaStatement.walCheckpointTruncate.sql)
    }

    // MARK: Inventory & counts

    public func fileInventory() throws -> [String: FileRow] {
        let statement = try database.prepare(StoreStatement.fileInventory.sql)
        var inventory: [String: FileRow] = [:]
        while try statement.step() {
            let row = fileRow(from: statement)
            inventory[row.path] = row
        }
        return inventory
    }

    public func fileRow(path: String) throws -> FileRow? {
        let statement = try database.prepare(StoreStatement.fileRowByPath.sql)
        statement.bind(1, path)
        guard try statement.step() else { return nil }
        return fileRow(from: statement)
    }

    private func fileRow(from statement: SQLiteStatement) -> FileRow {
        FileRow(
            id: statement.columnInt(0),
            path: statement.columnText(1),
            mtime: statement.columnDouble(2),
            size: statement.columnInt(3),
            contentHash: statement.columnText(4),
            module: statement.columnText(5),
            moduleGuessed: statement.columnInt(6) == 1,
            imports: statement.columnText(7).split(separator: " ").map(String.init),
            parseErrorCount: Int(statement.columnInt(8))
        )
    }

    /// Every file whose symbols are knowingly incomplete, ordered by path.
    ///
    /// The repo-wide set is small by construction — a handful of files in a tree of thousands — so callers that only care whether *their* answer is affected intersect this against their own paths rather than querying per path. Every file whose module was guessed rather than declared by a build file, ordered by path.
    ///
    /// Same shape and same reason as `filesWithParseErrors`: the set is small by construction, so an answer intersects it against its own paths rather than asking per file.
    public func filesWithGuessedModule() throws -> [FileRow] {
        let statement = try database.prepare(StoreStatement.filesWithGuessedModule.sql)
        var rows: [FileRow] = []
        while try statement.step() {
            rows.append(fileRow(from: statement))
        }
        return rows
    }

    public func filesWithParseErrors() throws -> [FileRow] {
        let statement = try database.prepare(StoreStatement.filesWithParseErrors.sql)
        var rows: [FileRow] = []
        while try statement.step() {
            rows.append(fileRow(from: statement))
        }
        return rows
    }

    public func counts() throws -> IndexCounts {
        let statement = try database.prepare(StoreStatement.counts.sql)
        guard try statement.step() else {
            return IndexCounts(files: 0, symbols: 0, parseErrorFiles: 0)
        }
        return IndexCounts(
            files: Int(statement.columnInt(0)),
            symbols: Int(statement.columnInt(1)),
            parseErrorFiles: Int(statement.columnInt(2))
        )
    }

    public func moduleNames() throws -> [String] {
        let statement = try database.prepare(StoreStatement.moduleNames.sql)
        var names: [String] = []
        while try statement.step() {
            names.append(statement.columnText(0))
        }
        return names
    }

    /// Per-module file and top-level declaration counts, ordered by module name — the repo overview digest's data.
    public func moduleOverview() throws -> [ModuleOverview] {
        let statement = try database.prepare(StoreStatement.moduleOverview.sql)
        var rows: [ModuleOverview] = []
        while try statement.step() {
            rows.append(ModuleOverview(
                module: statement.columnText(0),
                files: Int(statement.columnInt(1)),
                topLevelSymbols: Int(statement.columnInt(2))
            ))
        }
        return rows
    }

    /// Whether this store lives in memory only, as it does for a tree that cannot be written (``IndexLocation``).
    public var isInMemory: Bool {
        databasePath == Self.inMemoryPath
    }

    public var databaseSizeBytes: Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: databasePath)
        return (attributes?[.size] as? Int64) ?? 0
    }

    // MARK: Symbol queries

    private static var symbolSelect: String {
        StoreStatement.symbolSelectBase.sql
    }

    private func symbolRows(_ whereClause: String, order: String = "ORDER BY f.path, s.line", bind: (SQLiteStatement) -> Void) throws -> [SymbolRow] {
        let statement = try database.prepare("\(Self.symbolSelect) \(whereClause) \(order)")
        bind(statement)
        var rows: [SymbolRow] = []
        while try statement.step() {
            rows.append(symbolRow(from: statement))
        }
        return rows
    }

    private func symbolRow(from statement: SQLiteStatement) -> SymbolRow {
        SymbolRow(
            id: statement.columnInt(0),
            fileID: statement.columnInt(1),
            path: statement.columnText(2),
            module: statement.columnText(3),
            parentID: statement.columnIsNull(4) ? nil : statement.columnInt(4),
            kind: SymbolKind(rawValue: statement.columnText(5)) ?? .variable,
            name: statement.columnText(6),
            line: Int(statement.columnInt(7)),
            column: Int(statement.columnInt(8)),
            endLine: Int(statement.columnInt(9)),
            accessLevel: AccessLevel(rawValue: statement.columnText(10)) ?? .internalLevel,
            isStatic: statement.columnInt(11) == 1,
            isStored: statement.columnInt(12) == 1,
            signature: statement.columnText(13),
            docSummary: statement.columnOptionalText(14),
            ifConfigCondition: statement.columnOptionalText(15),
            viewOutline: statement.columnOptionalText(16)
        )
    }

    /// Nominal type declarations with the given bare name, optionally scoped to a module.
    public func typeDeclarations(named name: String, inModule module: String? = nil) throws -> [SymbolRow] {
        let clause = StoreStatement.typeDeclarationsClause(hasModule: module != nil)
        return try symbolRows(clause) { statement in
            statement.bind(1, name)
            if let module {
                statement.bind(2, module)
            }
        }
    }

    /// Extensions whose written extended-type name matches `name` exactly or as a `Prefix.name` suffix; the LIKE argument is escaped so `_`/`%` in identifiers stay literal.
    public func extensions(ofTypeNamed name: String) throws -> [SymbolRow] {
        try symbolRows(StoreStatement.extensionsClause.sql) { statement in
            statement.bind(1, name).bind(2, Self.escapedForLike(name))
        }
    }

    /// Extensions written with generic arguments after a final component that may be `name`, as `name<…>` or `Prefix.name<…>`: candidates only, since a name inside the arguments can match too.
    func extensions(specializingTypeNamed name: String) throws -> [SymbolRow] {
        try symbolRows(StoreStatement.specializedExtensionsClause.sql) { statement in
            statement.bind(1, name)
        }
    }

    /// Extensions written with array, dictionary or optional sugar (`extension [Gizmo]`, `extension Gizmo?`): candidates only, since the sugar on the outside decides the type extended.
    func sugaredExtensions() throws -> [SymbolRow] {
        try symbolRows(StoreStatement.sugaredExtensionsClause.sql) { _ in }
    }

    /// Escapes SQLite LIKE metacharacters so a bound identifier matches literally.
    static func escapedForLike(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// Direct members of a container symbol, in source order.
    public func children(of parentID: Int64) throws -> [SymbolRow] {
        try symbolRows(StoreStatement.childrenClause.sql, order: "ORDER BY s.\(SymbolsTable.line)") { statement in
            statement.bind(1, parentID)
        }
    }

    /// Symbols matching a name exactly, or as the base of a labeled function form.
    ///
    /// The labeled-form arm is a pure range scan — every `base(…)` name sorts between `base(` and `base)` — so it uses `idx_symbols_name` and treats `_`/`%` literally (no LIKE at all).
    public func symbols(named name: String) throws -> [SymbolRow] {
        try symbolRows(StoreStatement.symbolsNamedClause.sql) { statement in
            statement.bind(1, name)
        }
    }

    public func symbol(withID id: Int64) throws -> SymbolRow? {
        try symbolRows(StoreStatement.symbolByIDClause.sql) { statement in
            statement.bind(1, id)
        }.first
    }

    /// A symbol's fully qualified name, `Module.Outer.name`.
    ///
    /// One implementation because both faces must name the same symbol identically: a `where` declaration line and a `digest` header that disagreed would read as two different symbols, and the member-body path made that coupling load-bearing.
    public func qualifiedName(of row: SymbolRow) throws -> String {
        let chain = try parentChain(of: row).map(\.name)
        return ([row.module] + chain + [row.name]).joined(separator: ".")
    }

    /// The container chain of a symbol, outermost first.
    public func parentChain(of row: SymbolRow) throws -> [SymbolRow] {
        var chain: [SymbolRow] = []
        var currentParent = row.parentID
        while let parentID = currentParent {
            guard let parent = try symbol(withID: parentID) else { break }
            chain.insert(parent, at: 0)
            currentParent = parent.parentID
        }
        return chain
    }

    /// Type declarations and extensions whose inheritance clause names `name` (bare, generic-applied, or as the last component of a qualified path like `Outer.name`), alone or as one component of a composition (`Outer.name & Sendable`) — the generic arm is a range scan, the qualified arms case-sensitive globs.
    ///
    /// The index stores a composition as one entry, so an entry holding `&` and the name's text is a candidate the SQL cannot split, kept only where `InheritedClause` reads a component naming `name`.
    public func conformers(of name: String) throws -> [SymbolRow] {
        let candidates = try symbolRows(StoreStatement.conformerCandidatesClause.sql) { statement in
            statement.bind(1, name)
        }
        let written = try Set(symbolRows(StoreStatement.conformersClause.sql) { statement in
            statement.bind(1, name)
        }.map(\.id))
        guard candidates.count > written.count else { return candidates }
        return try candidates.filter { row in
            try written.contains(row.id) || InheritedClause.names(name, in: inheritedNames(of: row.id))
        }
    }

    /// The inheritance clause entries stored for a symbol.
    public func inheritedNames(of symbolID: Int64) throws -> [String] {
        let statement = try database.prepare(StoreStatement.inheritedNames.sql)
        statement.bind(1, symbolID)
        var names: [String] = []
        while try statement.step() {
            names.append(statement.columnText(0))
        }
        return names
    }

    /// FTS prefix candidates for the fuzzy fallback, capped; the term is phrase-quoted so FTS5 keywords (`AND`, `NOT`, …) stay searchable text.
    ///
    /// `qualifiers` is the whole path written before the missed member, outermost first and a module included where one was written — `["Settings", "DetailData"]` for `Settings.DetailData.load(i:)`, `["App", "Engine"]` for `App.Engine.start(mod:)` — and a candidate declared directly in whatever that path resolves to ranks ahead of every other candidate, inside the query and ahead of `LIMIT`, so a same-named crowd elsewhere can never outrank it off the page. Ties keep the existing name/path/line order.
    ///
    /// "Resolves to" is name resolution's own rule, ``QualifiedPath/matches(qualifiers:chain:module:)``, applied to each possible container (``containers(answering:)``) rather than approximated in SQL. An approximation is a second answer to "which type does this path name", and every shape it misses is one where the candidate list disowns the member resolution would have found: an extension stored under its whole dotted path, a type nested inside such an extension, a suffix of the chain, a chain deeper than the approximation looks, a module written in front.
    public func searchCandidates(prefix: String, limit: Int, qualifiers: [String] = []) throws -> [SymbolRow] {
        let sanitized = prefix.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        guard !sanitized.isEmpty else { return [] }
        var belongs: [String] = []
        let owners = try containers(answering: qualifiers)
        if !owners.isEmpty {
            // Row ids are integers this store assigned, so writing them into the statement is not interpolating input.
            // `IN` over a NULL `parent_id` (a top-level declaration) evaluates to SQL NULL, not 0 — and `ORDER BY … DESC`
            // sorts NULL after 0, so a top-level candidate would rank below every unrelated member instead of tying
            // with them. `COALESCE` turns that NULL into a definite non-match, which is what a top-level row already
            // is with respect to a container's own children.
            belongs.append("COALESCE(s.\(SymbolsTable.parentID) IN (\(owners.map(String.init).joined(separator: ","))), 0)")
        }
        if qualifiers.count == 1 {
            // A lone qualifier can be the module itself (`App.start(mod:)`), and a top-level declaration answers to
            // its module with no container between them — the one match the rule makes that no container row carries.
            belongs.append("(s.\(SymbolsTable.parentID) IS NULL AND f.\(FilesTable.module) = ?2)")
        }
        let rank = belongs.isEmpty ? "" : "(\(belongs.joined(separator: " OR "))) DESC, "
        return try symbolRows(
            "WHERE s.\(SymbolsTable.id) IN (SELECT \(SymbolsFTSTable.rowid) FROM \(SymbolsFTSTable.name) WHERE \(SymbolsFTSTable.name) MATCH ?1)",
            order: "ORDER BY \(rank)s.\(SymbolsTable.symbolName), f.\(FilesTable.path), s.\(SymbolsTable.line) LIMIT \(limit)"
        ) { statement in
            statement.bind(1, "\"\(sanitized)\"*")
            if qualifiers.count == 1 {
                statement.bind(2, qualifiers[0])
            }
        }
    }
}

/// Split from the class body to keep it under SwiftLint's type-body-length cap; internal, unlike the public queries below it, because only this module's renderers and reports read either.
extension IndexStore {
    /// Every symbol a member written under `qualifiers` could be declared directly in — by name resolution's own rule, so ranking and resolution can never disagree about which type a path names.
    ///
    /// Looked up by the path's last component, the one part a container's own name must carry: as its whole name, or — for an extension, whose row keeps the whole dotted path it was written with — as that path's last component. Each is then judged by ``QualifiedPath/matches(qualifiers:chain:module:)`` against its own enclosing chain plus its own name, which is exactly the chain a member declared in it is resolved against.
    func containers(answering qualifiers: [String]) throws -> [Int64] {
        guard let last = qualifiers.last else { return [] }
        let rows = try symbolRows(StoreStatement.containersClause.sql) { statement in
            statement.bind(1, last).bind(2, Self.escapedForLike(last))
        }
        return try rows.filter { row in
            try QualifiedPath.matches(qualifiers: qualifiers, chain: parentChain(of: row).map(\.name) + [row.name], module: row.module)
        }.map(\.id)
    }

    /// Every `typealias` declaration in the repository, top-level and nested.
    func everyTypealias() throws -> [SymbolRow] {
        try symbolRows(StoreStatement.everyTypealiasClause.sql) { _ in }
    }

    /// Every `macro` declaration in the repository.
    func everyMacro() throws -> [SymbolRow] {
        try symbolRows(StoreStatement.everyMacroClause.sql) { _ in }
    }

    /// Every `typealias` declaration written in the given files, in path + line order.
    ///
    /// The candidates for a use the store recorded against an alias rather than against the type it names — the typealias fold a type's usage verdict opens with: a reference hit landing inside one of these spans is the type being aliased, and what a reader writes at a use site is then the alias.
    ///
    /// **One statement per chunk of files, never one per file.** This runs on the default `where` path for every type, whose references can touch more files than a single statement may bind variables for, so the paths are chunked rather than queried one at a time — a query per reference file would make a type's usage cost grow with the size of the repository it is used in.
    func typealiases(inFiles paths: [String]) throws -> [SymbolRow] {
        var rows: [SymbolRow] = []
        for start in stride(from: 0, to: paths.count, by: Self.boundPathChunk) {
            let chunk = Array(paths[start ..< min(start + Self.boundPathChunk, paths.count)])
            rows += try symbolRows(StoreStatement.typealiasesClause(placeholderCount: chunk.count)) { statement in
                for (offset, path) in chunk.enumerated() {
                    statement.bind(Int32(offset + 1), path)
                }
            }
        }
        return rows
    }

    /// Paths bound into one `IN (…)` list, well under the oldest bound-variable cap a system SQLite ships with.
    private static var boundPathChunk: Int {
        400
    }

    /// The files this index has dropped, and when — see ``DeletionLedger``.
    func deletionLedger() throws -> DeletionLedger {
        try DeletionLedger(metaValue: metaValue(DeletionLedger.metaKey))
    }

    /// Whether this store has never kept a ``DeletionLedger`` — no drop recorded and no seed written — which is the one state the seed below acts on.
    var lacksDeletionLedger: Bool {
        get throws { try metaValue(DeletionLedger.metaKey) == nil }
    }

    /// Seeds a store that has never kept a ``DeletionLedger`` with paths deleted before it held a row for them, timestamped `at` — what git still records of each deletion, gathered by `Indexer.seedDeletionLedgerIfAbsent(listed:storeBuiltAt:at:)` — and writes the ledger even when there is nothing to seed, so this runs once per store.
    ///
    /// The one signal a store has for a deletion it never recorded: `sift reset`, a schema-version rebuild, or a `.sift/` a `git clean` wiped all lose the ledger, and the fresh store that follows has no row to drop for a file already gone; a store written by a binary from before the ledger dropped the file's rows without recording anything. Either way ``deleteFiles`` alone never records it (Docs/Design.md §2). Keyed on the ledger being absent rather than empty, because an empty ledger written here is the record that the seed already ran — a later call must never re-stamp what a real drop, or this seed, already dated. Over-warning is the direction this may err in.
    func seedDeletionLedgerIfAbsent(missingPaths: [String], at instant: Date = Date()) throws {
        try database.inTransaction {
            guard try lacksDeletionLedger else { return }
            var ledger = DeletionLedger(metaValue: nil)
            ledger.record(missingPaths, at: instant.timeIntervalSince1970)
            try setMetaValue(ledger.metaValue, forKey: DeletionLedger.metaKey)
        }
    }
}

/// Split from the class body to keep it under SwiftLint's type-body-length cap.
///
/// These are ordinary queries like every other in this file; `symbolRows` and `database` stay reachable, since a same-file extension of a type sees its `private` members exactly as the primary declaration does.
public extension IndexStore {
    /// Direct-member count of a container — a COUNT query, not row materialization.
    func childCount(of parentID: Int64) throws -> Int {
        let statement = try database.prepare(StoreStatement.childCount.sql)
        statement.bind(1, parentID)
        guard try statement.step() else { return 0 }
        return Int(statement.columnInt(0))
    }

    /// Refreshes a file's stored mtime after a content-hash match proved a reparse unnecessary.
    func updateMtime(path: String, mtime: Double) throws {
        let statement = try database.prepare(StoreStatement.updateMtime.sql)
        statement.bind(1, mtime).bind(2, path)
        try statement.run()
    }

    /// Top-level symbols of one file, in source order.
    func topLevelSymbols(inFileID fileID: Int64) throws -> [SymbolRow] {
        try symbolRows(StoreStatement.topLevelSymbolsInFileClause.sql, order: "ORDER BY s.\(SymbolsTable.line)") { statement in
            statement.bind(1, fileID)
        }
    }

    /// Every declaration in one file at every nesting level, outermost first — what `affected` resolves a changed file to, and what it resolves an occurrence line back through.
    ///
    /// Ordered by start line then by *widest* range first, so a containing declaration always precedes the members nested inside it and a reader scanning the list sees the file's shape in source order.
    func symbols(inFile path: String) throws -> [SymbolRow] {
        try symbolRows(
            StoreStatement.symbolsInFileClause.sql,
            order: "ORDER BY s.\(SymbolsTable.line), s.\(SymbolsTable.endLine) DESC"
        ) { statement in
            statement.bind(1, path)
        }
    }

    /// Top-level symbols of one module, in path + source order.
    func topLevelSymbols(inModule module: String) throws -> [SymbolRow] {
        try symbolRows(StoreStatement.topLevelSymbolsInModuleClause.sql) { statement in
            statement.bind(1, module)
        }
    }
}
