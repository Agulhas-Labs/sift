//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins every typed SQL constant and statement against the literal text captured from the tree at `7241bf64` — a renamed table or column constant that changes the rendered SQL fails here.
@Suite(.temporaryDirectories)
struct TypedSQLStatementTests {
    /// Every typed statement/clause paired with the exact literal SQL it replaced.
    private static var pinnedPairs: [PinnedPair] {
        [
            PinnedPair("foreignKeysOn", PragmaStatement.foreignKeysOn.sql, "PRAGMA foreign_keys = ON"),
            PinnedPair("busyTimeout5000", PragmaStatement.busyTimeout5000.sql, "PRAGMA busy_timeout = 5000"),
            PinnedPair("busyTimeout1000", PragmaStatement.busyTimeout1000.sql, "PRAGMA busy_timeout = 1000"),
            PinnedPair("userVersionRead", PragmaStatement.userVersionRead.sql, "PRAGMA user_version"),
            PinnedPair("userVersionWrite", PragmaStatement.userVersionWrite(6).sql, "PRAGMA user_version = 6"),
            PinnedPair("journalSizeLimit", PragmaStatement.journalSizeLimit.sql, "PRAGMA journal_size_limit = 33554432"),
            PinnedPair("autoVacuumIncremental", PragmaStatement.autoVacuumIncremental.sql, "PRAGMA auto_vacuum = INCREMENTAL"),
            PinnedPair("journalModeWAL", PragmaStatement.journalModeWAL.sql, "PRAGMA journal_mode = WAL"),
            PinnedPair("synchronousNormal", PragmaStatement.synchronousNormal.sql, "PRAGMA synchronous = NORMAL"),
            PinnedPair("incrementalVacuum", PragmaStatement.incrementalVacuum.sql, "PRAGMA incremental_vacuum"),
            PinnedPair("walCheckpointTruncate", PragmaStatement.walCheckpointTruncate.sql, "PRAGMA wal_checkpoint(TRUNCATE)"),
            PinnedPair("begin", TransactionStatement.begin.sql, "BEGIN IMMEDIATE"),
            PinnedPair("commit", TransactionStatement.commit.sql, "COMMIT"),
            PinnedPair("rollback", TransactionStatement.rollback.sql, "ROLLBACK"),
            PinnedPair("dropInherited", SchemaDDLStatement.dropInherited.sql, "DROP TABLE IF EXISTS inherited"),
            PinnedPair("dropSymbolsFTS", SchemaDDLStatement.dropSymbolsFTS.sql, "DROP TABLE IF EXISTS symbols_fts"),
            PinnedPair("dropSymbols", SchemaDDLStatement.dropSymbols.sql, "DROP TABLE IF EXISTS symbols"),
            PinnedPair("dropFiles", SchemaDDLStatement.dropFiles.sql, "DROP TABLE IF EXISTS files"),
            PinnedPair("dropMeta", SchemaDDLStatement.dropMeta.sql, "DROP TABLE IF EXISTS meta"),
            PinnedPair(
                "createMeta", SchemaDDLStatement.createMeta.sql,
                """
                CREATE TABLE IF NOT EXISTS meta(
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                )
                """
            ),
            PinnedPair(
                "createFiles", SchemaDDLStatement.createFiles.sql,
                """
                CREATE TABLE IF NOT EXISTS files(
                    id INTEGER PRIMARY KEY,
                    path TEXT NOT NULL UNIQUE,
                    mtime REAL NOT NULL,
                    size INTEGER NOT NULL,
                    content_hash TEXT NOT NULL,
                    module TEXT NOT NULL,
                    module_guessed INTEGER NOT NULL,
                    imports TEXT NOT NULL,
                    parse_error_count INTEGER NOT NULL
                )
                """
            ),
            PinnedPair(
                "createSymbols", SchemaDDLStatement.createSymbols.sql,
                """
                CREATE TABLE IF NOT EXISTS symbols(
                    id INTEGER PRIMARY KEY,
                    file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                    parent_id INTEGER,
                    kind TEXT NOT NULL,
                    name TEXT NOT NULL,
                    line INTEGER NOT NULL,
                    column INTEGER NOT NULL,
                    end_line INTEGER NOT NULL,
                    access TEXT NOT NULL,
                    is_static INTEGER NOT NULL,
                    is_stored INTEGER NOT NULL,
                    signature TEXT NOT NULL,
                    doc_summary TEXT,
                    if_config TEXT,
                    view_outline TEXT
                )
                """
            ),
            PinnedPair(
                "createInherited", SchemaDDLStatement.createInherited.sql,
                """
                CREATE TABLE IF NOT EXISTS inherited(
                    symbol_id INTEGER NOT NULL REFERENCES symbols(id) ON DELETE CASCADE,
                    name TEXT NOT NULL,
                    position INTEGER NOT NULL
                )
                """
            ),
            PinnedPair("indexSymbolsName", SchemaDDLStatement.indexSymbolsName.sql, "CREATE INDEX IF NOT EXISTS idx_symbols_name ON symbols(name)"),
            PinnedPair("indexSymbolsFile", SchemaDDLStatement.indexSymbolsFile.sql, "CREATE INDEX IF NOT EXISTS idx_symbols_file ON symbols(file_id)"),
            PinnedPair(
                "indexSymbolsParent", SchemaDDLStatement.indexSymbolsParent.sql,
                "CREATE INDEX IF NOT EXISTS idx_symbols_parent ON symbols(parent_id)"
            ),
            PinnedPair(
                "indexInheritedName", SchemaDDLStatement.indexInheritedName.sql,
                "CREATE INDEX IF NOT EXISTS idx_inherited_name ON inherited(name)"
            ),
            PinnedPair(
                "indexInheritedSymbol", SchemaDDLStatement.indexInheritedSymbol.sql,
                "CREATE INDEX IF NOT EXISTS idx_inherited_symbol ON inherited(symbol_id)"
            ),
            PinnedPair("indexFilesModule", SchemaDDLStatement.indexFilesModule.sql, "CREATE INDEX IF NOT EXISTS idx_files_module ON files(module)"),
            PinnedPair(
                "createSymbolsFTS", SchemaDDLStatement.createSymbolsFTS.sql,
                "CREATE VIRTUAL TABLE IF NOT EXISTS symbols_fts USING fts5(name)"
            ),
            PinnedPair("metaGet", StoreStatement.metaGet.sql, "SELECT value FROM meta WHERE key = ?"),
            PinnedPair(
                "metaSet", StoreStatement.metaSet.sql,
                "INSERT INTO meta(key, value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value = excluded.value"
            ),
            PinnedPair("reattributeUpdate", StoreStatement.reattributeUpdate.sql, "UPDATE files SET module = ?, module_guessed = ? WHERE id = ?"),
            PinnedPair("deleteFileLookup", StoreStatement.deleteFileLookup.sql, "SELECT id FROM files WHERE path = ?"),
            PinnedPair(
                "deleteFtsRows", StoreStatement.deleteFtsRows.sql,
                "DELETE FROM symbols_fts WHERE rowid IN (SELECT id FROM symbols WHERE file_id = ?)"
            ),
            PinnedPair("deleteFileRow", StoreStatement.deleteFileRow.sql, "DELETE FROM files WHERE id = ?"),
            PinnedPair(
                "insertFile", StoreStatement.insertFile.sql,
                """
                INSERT INTO files(path, mtime, size, content_hash, module, module_guessed, imports, parse_error_count)
                VALUES(?,?,?,?,?,?,?,?)
                """
            ),
            PinnedPair(
                "insertSymbol", StoreStatement.insertSymbol.sql,
                """
                INSERT INTO symbols(file_id, parent_id, kind, name, line, column, end_line, access, is_static, is_stored, signature, doc_summary, if_config, view_outline)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """
            ),
            PinnedPair("insertInherited", StoreStatement.insertInherited.sql, "INSERT INTO inherited(symbol_id, name, position) VALUES(?,?,?)"),
            PinnedPair("insertFtsSymbol", StoreStatement.insertFtsSymbol.sql, "INSERT INTO symbols_fts(rowid, name) VALUES(?,?)"),
            PinnedPair("ftsOptimize", StoreStatement.ftsOptimize.sql, "INSERT INTO symbols_fts(symbols_fts) VALUES('optimize')"),
            PinnedPair(
                "fileInventory", StoreStatement.fileInventory.sql,
                "SELECT id, path, mtime, size, content_hash, module, module_guessed, imports, parse_error_count FROM files"
            ),
            PinnedPair(
                "fileRowByPath", StoreStatement.fileRowByPath.sql,
                "SELECT id, path, mtime, size, content_hash, module, module_guessed, imports, parse_error_count FROM files WHERE path = ?"
            ),
            PinnedPair(
                "filesWithGuessedModule", StoreStatement.filesWithGuessedModule.sql,
                "SELECT id, path, mtime, size, content_hash, module, module_guessed, imports, parse_error_count FROM files WHERE module_guessed = 1 ORDER BY path"
            ),
            PinnedPair(
                "filesWithParseErrors", StoreStatement.filesWithParseErrors.sql,
                "SELECT id, path, mtime, size, content_hash, module, module_guessed, imports, parse_error_count FROM files WHERE parse_error_count > 0 ORDER BY path"
            ),
            PinnedPair(
                "counts", StoreStatement.counts.sql,
                """
                SELECT (SELECT COUNT(*) FROM files),
                       (SELECT COUNT(*) FROM symbols),
                       (SELECT COUNT(*) FROM files WHERE parse_error_count > 0)
                """
            ),
            PinnedPair("moduleNames", StoreStatement.moduleNames.sql, "SELECT DISTINCT module FROM files ORDER BY module"),
            PinnedPair(
                "moduleOverview", StoreStatement.moduleOverview.sql,
                """
                SELECT f.module,
                       COUNT(DISTINCT f.id),
                       COUNT(CASE WHEN s.parent_id IS NULL THEN s.id END)
                FROM files f
                LEFT JOIN symbols s ON s.file_id = f.id
                GROUP BY f.module
                ORDER BY f.module
                """
            ),
            PinnedPair(
                "symbolSelectBase", StoreStatement.symbolSelectBase.sql,
                """
                SELECT s.id, s.file_id, f.path, f.module, s.parent_id, s.kind, s.name, s.line, s.column, s.end_line,
                       s.access, s.is_static, s.is_stored, s.signature, s.doc_summary, s.if_config, s.view_outline
                FROM symbols s JOIN files f ON f.id = s.file_id
                """
            ),
            PinnedPair(
                "extensionsClause", StoreStatement.extensionsClause.sql,
                "WHERE s.kind = 'extension' AND (s.name = ? OR s.name LIKE '%.' || ? ESCAPE '\\')"
            ),
            PinnedPair(
                "specializedExtensionsClause", StoreStatement.specializedExtensionsClause.sql,
                "WHERE s.kind = 'extension' AND (s.name GLOB ?1 || '<*' OR s.name GLOB '*.' || ?1 || '<*')"
            ),
            PinnedPair(
                "sugaredExtensionsClause", StoreStatement.sugaredExtensionsClause.sql,
                "WHERE s.kind = 'extension' AND (substr(s.name, 1, 1) = '[' OR substr(s.name, -1) = '?')"
            ),
            PinnedPair("childrenClause", StoreStatement.childrenClause.sql, "WHERE s.parent_id = ?"),
            PinnedPair("symbolByIDClause", StoreStatement.symbolByIDClause.sql, "WHERE s.id = ?"),
            PinnedPair(
                "symbolsNamedClause", StoreStatement.symbolsNamedClause.sql,
                "WHERE s.name = ?1 OR (s.name >= ?1 || '(' AND s.name < ?1 || ')')"
            ),
            PinnedPair(
                "conformersClause", StoreStatement.conformersClause.sql,
                "WHERE s.id IN (SELECT symbol_id FROM inherited WHERE name = ?1 OR (name >= ?1 || '<' AND name < ?1 || '=') OR name GLOB '*.' || ?1 OR name GLOB '*.' || ?1 || '<*')"
            ),
            PinnedPair(
                "conformerCandidatesClause", StoreStatement.conformerCandidatesClause.sql,
                "WHERE s.id IN (SELECT symbol_id FROM inherited WHERE name = ?1 OR (name >= ?1 || '<' AND name < ?1 || '=') OR name GLOB '*.' || ?1 OR name GLOB '*.' || ?1 || '<*')"
                    + " OR s.id IN (SELECT symbol_id FROM inherited WHERE instr(name, '&') > 0 AND instr(name, ?1) > 0)"
            ),
            PinnedPair(
                "containersClause", StoreStatement.containersClause.sql,
                "WHERE s.name = ? OR (s.kind = 'extension' AND s.name LIKE '%.' || ? ESCAPE '\\')"
            ),
            PinnedPair("inheritedNames", StoreStatement.inheritedNames.sql, "SELECT name FROM inherited WHERE symbol_id = ? ORDER BY position"),
            PinnedPair("childCount", StoreStatement.childCount.sql, "SELECT COUNT(*) FROM symbols WHERE parent_id = ?"),
            PinnedPair("updateMtime", StoreStatement.updateMtime.sql, "UPDATE files SET mtime = ? WHERE path = ?"),
            PinnedPair(
                "topLevelSymbolsInFileClause", StoreStatement.topLevelSymbolsInFileClause.sql,
                "WHERE s.file_id = ? AND s.parent_id IS NULL"
            ),
            PinnedPair(
                "topLevelSymbolsInModuleClause", StoreStatement.topLevelSymbolsInModuleClause.sql,
                "WHERE f.module = ? AND s.parent_id IS NULL"
            ),
            PinnedPair("symbolsInFileClause", StoreStatement.symbolsInFileClause.sql, "WHERE f.path = ?"),
            PinnedPair("everyTypealiasClause", StoreStatement.everyTypealiasClause.sql, "WHERE s.kind = 'typealias'"),
            PinnedPair("everyMacroClause", StoreStatement.everyMacroClause.sql, "WHERE s.kind = 'macro'"),
            PinnedPair(
                "typeDeclarationsClause(hasModule: false)", StoreStatement.typeDeclarationsClause(hasModule: false),
                "WHERE s.name = ? AND s.kind IN ('struct','class','actor','enum','protocol')"
            ),
            PinnedPair(
                "typeDeclarationsClause(hasModule: true)", StoreStatement.typeDeclarationsClause(hasModule: true),
                "WHERE s.name = ? AND s.kind IN ('struct','class','actor','enum','protocol') AND f.module = ?"
            ),
            PinnedPair(
                "typealiasesClause(3)", StoreStatement.typealiasesClause(placeholderCount: 3),
                "WHERE s.kind = 'typealias' AND f.path IN (?, ?, ?)"
            ),
            PinnedPair(
                "fileAndGuessedModuleCounts", ReadOnlyIndexStatement.fileAndGuessedModuleCounts.sql,
                "SELECT COUNT(*), SUM(module_guessed) FROM files"
            ),
            PinnedPair("beginSnapshot", ReadOnlyIndexStatement.beginSnapshot.sql, "BEGIN DEFERRED"),
            PinnedPair("fileCount", ReadOnlyIndexStatement.fileCount.sql, "SELECT COUNT(*) FROM files"),
            PinnedPair("indexedHead", ReadOnlyIndexStatement.indexedHead.sql, "SELECT value FROM meta WHERE key = 'indexed_head'"),
            PinnedPair(
                "declaresName", SiblingProbeStatement.declaresName.sql,
                "SELECT 1 FROM symbols WHERE (name = ?1 OR (name >= ?1 || '(' AND name < ?1 || ')')) AND kind != 'extension' LIMIT 1"
            ),
            PinnedPair("extendsName", SiblingProbeStatement.extendsName.sql, "SELECT 1 FROM symbols WHERE name = ?1 AND kind = 'extension' LIMIT 1"),
            PinnedPair("recordsPath", SiblingProbeStatement.recordsPath.sql, "SELECT 1 FROM files WHERE path = ? LIMIT 1"),
            PinnedPair(
                "candidatesByLastComponent", SiblingProbeStatement.candidatesByLastComponent.sql,
                """
                SELECT s.id, f.module FROM symbols s JOIN files f ON f.id = s.file_id
                WHERE (s.name = ?1 OR (s.name >= ?1 || '(' AND s.name < ?1 || ')')) AND s.kind != 'extension'
                """
            ),
            PinnedPair(
                "candidatesByLastComponentWithPath", SiblingProbeStatement.candidatesByLastComponentWithPath.sql,
                """
                SELECT s.id, f.path, f.module FROM symbols s JOIN files f ON f.id = s.file_id
                WHERE (s.name = ?1 OR (s.name >= ?1 || '(' AND s.name < ?1 || ')')) AND s.kind != 'extension'
                """
            ),
            PinnedPair("enclosingNames", SiblingProbeStatement.enclosingNames.sql, "SELECT name, parent_id FROM symbols WHERE id = ?"),
            PinnedPair("allPaths", RunFailureSitesStatement.allPaths.sql, "SELECT path FROM files"),
        ]
    }

    @Test
    func everyTypedStatementRendersByteIdenticalToTheStringItReplaced() {
        for pair in Self.pinnedPairs {
            #expect(pair.typed == pair.literal, "\(pair.name) diverged from its captured literal")
        }
    }

    /// `EXPLAIN QUERY PLAN` for every full, directly-runnable `SELECT` above, read against a freshly built store, is identical whichever of the pinned pair's two strings runs it — proving the constant substitution changed no index SQLite would pick.
    @Test
    func explainQueryPlanIsIdenticalForEveryRunnableSelect() throws {
        let directory = try TestSources.makeTempDirectory()
        let database = try SQLiteDatabase(path: directory.appendingPathComponent("plan.db").path)
        for statement in IndexSchema.createStatements {
            try database.execute(statement)
        }

        let runnable = Self.pinnedPairs.filter { pair in
            let upper = pair.typed.uppercased()
            return upper.hasPrefix("SELECT") && !pair.typed.contains("?1,")
        }
        #expect(!runnable.isEmpty)
        for pair in runnable {
            #expect(Self.queryPlan(pair.typed, in: database) == Self.queryPlan(pair.literal, in: database), "\(pair.name) plan diverged")
        }
    }

    private static func queryPlan(_ sql: String, in database: SQLiteDatabase) -> [String] {
        guard let statement = try? database.prepare("EXPLAIN QUERY PLAN \(sql)") else { return [] }
        var rows: [String] = []
        while (try? statement.step()) == true {
            rows.append("\(statement.columnInt(0)):\(statement.columnInt(1)):\(statement.columnText(3))")
        }
        return rows
    }
}

extension TypedSQLStatementTests {
    /// One typed statement or clause paired with the exact literal SQL it replaced.
    private struct PinnedPair {
        let name: String
        let typed: String
        let literal: String

        init(_ name: String, _ typed: String, _ literal: String) {
            self.name = name
            self.typed = typed
            self.literal = literal
        }
    }
}
