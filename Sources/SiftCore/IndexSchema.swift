//
// Copyright © Agulhas Labs
//

/// The database DDL and its version — bump the version for any shape change; mismatch means drop and rebuild, never migrate (Docs/Design.md §6.6).
struct IndexSchema {
    /// Stored in `PRAGMA user_version`; readable before any table exists.
    ///
    /// v2 added idx_inherited_symbol, v3 symbols.view_outline, v4 files.module_guessed, v5 the doc-summary cap, v6 the names the index store gives a subscript (`subscript(_:)`, not `subscript(slot:)`) and an enum case with associated values (`value(_:)`, not `value`), v7 signatures stored whole rather than cut at 200 characters, v8 no rows held under a symbolic link's path, v9 a scoped import stored as its module, v10 a declared name stored without the backticks that escape an ordinary word (`settle()`, not `` `settle`() ``), v11 an enum case's signature stored without the comma after it in `case a, b` (`case a`, not `case a,`).
    ///
    /// A change to what a stored column *holds* is a shape change too, even with the DDL untouched. `doc_summary` is derived at parse time and never re-derived for a file that has not changed, so without the bump an upgraded binary would go on serving the old rule's summaries for every unchanged file, indefinitely. `symbols.name` is the same: an unchanged file's subscripts and enum cases would keep the old spelling, which no store row carries, and go on being refused. A change to which paths hold rows at all is one as well: an upgraded binary would otherwise keep a symbolic link's stale rows until a reconcile happened to run.
    static var version: Int32 {
        11
    }

    /// Every schema object, dependents first — the drop order for a version-mismatch rebuild (dropping in-place instead of deleting files another process may hold open).
    static var dropStatements: [String] {
        [
            SchemaDDLStatement.dropInherited.sql,
            SchemaDDLStatement.dropSymbolsFTS.sql,
            SchemaDDLStatement.dropSymbols.sql,
            SchemaDDLStatement.dropFiles.sql,
            SchemaDDLStatement.dropMeta.sql,
        ]
    }

    /// Pragmas that must run before the first table is created on a fresh database.
    static var preCreationPragmas: [String] {
        [
            PragmaStatement.autoVacuumIncremental.sql,
            PragmaStatement.journalModeWAL.sql,
            PragmaStatement.journalSizeLimit.sql,
            PragmaStatement.synchronousNormal.sql,
        ]
    }

    static var createStatements: [String] {
        [
            SchemaDDLStatement.createMeta.sql,
            SchemaDDLStatement.createFiles.sql,
            SchemaDDLStatement.createSymbols.sql,
            SchemaDDLStatement.createInherited.sql,
            SchemaDDLStatement.indexSymbolsName.sql,
            SchemaDDLStatement.indexSymbolsFile.sql,
            SchemaDDLStatement.indexSymbolsParent.sql,
            SchemaDDLStatement.indexInheritedName.sql,
            SchemaDDLStatement.indexInheritedSymbol.sql,
            SchemaDDLStatement.indexFilesModule.sql,
            SchemaDDLStatement.createSymbolsFTS.sql,
        ]
    }
}
