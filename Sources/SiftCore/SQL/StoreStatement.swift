//
// Copyright © Agulhas Labs
//

/// Every statement `IndexStore` runs that has one fixed shape — full statements, and the WHERE clauses `symbolRows` fills in for a query with no branching of its own — built from the table and column constants so a renamed column fails to compile here rather than at runtime.
///
/// A query whose shape actually varies (an optional module filter, a ranked search, a chunked `IN` list) stays a function that builds its text from the same constants, because there is no one fixed string for an enum case to hold.
enum StoreStatement {
    case metaGet
    case metaSet
    case reattributeUpdate
    case deleteFileLookup
    case deleteFtsRows
    case deleteFileRow
    case insertFile
    case insertSymbol
    case insertInherited
    case insertFtsSymbol
    case ftsOptimize
    case fileInventory
    case fileRowByPath
    case filesWithGuessedModule
    case filesWithParseErrors
    case counts
    case moduleNames
    case moduleOverview
    case symbolSelectBase
    case extensionsClause
    case specializedExtensionsClause
    case sugaredExtensionsClause
    case childrenClause
    case symbolByIDClause
    case symbolsNamedClause
    case conformersClause
    case conformerCandidatesClause
    case containersClause
    case inheritedNames
    case childCount
    case updateMtime
    case topLevelSymbolsInFileClause
    case topLevelSymbolsInModuleClause
    case symbolsInFileClause
    case everyTypealiasClause
    case everyMacroClause

    private static var fileColumns: String {
        [
            FilesTable.id, FilesTable.path, FilesTable.mtime, FilesTable.size, FilesTable.contentHash,
            FilesTable.module, FilesTable.moduleGuessed, FilesTable.imports, FilesTable.parseErrorCount,
        ].joined(separator: ", ")
    }

    /// The clause naming a nominal-type declaration by bare name, kind-filtered, with an optional module filter appended.
    static func typeDeclarationsClause(hasModule: Bool) -> String {
        var clause = "WHERE s.\(SymbolsTable.symbolName) = ? AND s.\(SymbolsTable.kind) IN ('struct','class','actor','enum','protocol')"
        if hasModule {
            clause += " AND f.\(FilesTable.module) = ?"
        }
        return clause
    }

    /// The `typealias` clause for a chunk of `placeholderCount` bound paths.
    static func typealiasesClause(placeholderCount: Int) -> String {
        let placeholders = Array(repeating: "?", count: placeholderCount).joined(separator: ", ")
        return "WHERE s.\(SymbolsTable.kind) = 'typealias' AND f.\(FilesTable.path) IN (\(placeholders))"
    }

    var sql: String {
        switch self {
        case .metaGet: "SELECT \(MetaTable.value) FROM \(MetaTable.name) WHERE \(MetaTable.key) = ?"
        case .metaSet:
            "INSERT INTO \(MetaTable.name)(\(MetaTable.key), \(MetaTable.value)) VALUES(?,?) ON CONFLICT(\(MetaTable.key)) DO UPDATE SET \(MetaTable.value) = excluded.\(MetaTable.value)"
        case .reattributeUpdate:
            "UPDATE \(FilesTable.name) SET \(FilesTable.module) = ?, \(FilesTable.moduleGuessed) = ? WHERE \(FilesTable.id) = ?"
        case .deleteFileLookup: "SELECT \(FilesTable.id) FROM \(FilesTable.name) WHERE \(FilesTable.path) = ?"
        case .deleteFtsRows:
            "DELETE FROM \(SymbolsFTSTable.name) WHERE \(SymbolsFTSTable.rowid) IN (SELECT \(SymbolsTable.id) FROM \(SymbolsTable.name) WHERE \(SymbolsTable.fileID) = ?)"
        case .deleteFileRow: "DELETE FROM \(FilesTable.name) WHERE \(FilesTable.id) = ?"
        case .insertFile:
            """
            INSERT INTO \(FilesTable.name)(\(FilesTable.path), \(FilesTable.mtime), \(FilesTable.size), \(FilesTable.contentHash), \(FilesTable.module), \(FilesTable.moduleGuessed), \(FilesTable.imports), \(FilesTable.parseErrorCount))
            VALUES(?,?,?,?,?,?,?,?)
            """
        case .insertSymbol:
            """
            INSERT INTO \(SymbolsTable.name)(\(SymbolsTable.fileID), \(SymbolsTable.parentID), \(SymbolsTable.kind), \(SymbolsTable.symbolName), \(SymbolsTable.line), \(SymbolsTable.column), \(SymbolsTable.endLine), \(SymbolsTable.access), \(SymbolsTable.isStatic), \(SymbolsTable.isStored), \(SymbolsTable.signature), \(SymbolsTable.docSummary), \(SymbolsTable.ifConfig), \(SymbolsTable.viewOutline))
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """
        case .insertInherited:
            "INSERT INTO \(InheritedTable.name)(\(InheritedTable.symbolID), \(InheritedTable.inheritedName), \(InheritedTable.position)) VALUES(?,?,?)"
        case .insertFtsSymbol:
            "INSERT INTO \(SymbolsFTSTable.name)(\(SymbolsFTSTable.rowid), \(SymbolsFTSTable.ftsName)) VALUES(?,?)"
        case .ftsOptimize: "INSERT INTO \(SymbolsFTSTable.name)(\(SymbolsFTSTable.name)) VALUES('optimize')"
        case .fileInventory: "SELECT \(Self.fileColumns) FROM \(FilesTable.name)"
        case .fileRowByPath: "SELECT \(Self.fileColumns) FROM \(FilesTable.name) WHERE \(FilesTable.path) = ?"
        case .filesWithGuessedModule:
            "SELECT \(Self.fileColumns) FROM \(FilesTable.name) WHERE \(FilesTable.moduleGuessed) = 1 ORDER BY \(FilesTable.path)"
        case .filesWithParseErrors:
            "SELECT \(Self.fileColumns) FROM \(FilesTable.name) WHERE \(FilesTable.parseErrorCount) > 0 ORDER BY \(FilesTable.path)"
        case .counts:
            """
            SELECT (SELECT COUNT(*) FROM \(FilesTable.name)),
                   (SELECT COUNT(*) FROM \(SymbolsTable.name)),
                   (SELECT COUNT(*) FROM \(FilesTable.name) WHERE \(FilesTable.parseErrorCount) > 0)
            """
        case .moduleNames: "SELECT DISTINCT \(FilesTable.module) FROM \(FilesTable.name) ORDER BY \(FilesTable.module)"
        case .moduleOverview:
            """
            SELECT f.\(FilesTable.module),
                   COUNT(DISTINCT f.\(FilesTable.id)),
                   COUNT(CASE WHEN s.\(SymbolsTable.parentID) IS NULL THEN s.\(SymbolsTable.id) END)
            FROM \(FilesTable.name) f
            LEFT JOIN \(SymbolsTable.name) s ON s.\(SymbolsTable.fileID) = f.\(FilesTable.id)
            GROUP BY f.\(FilesTable.module)
            ORDER BY f.\(FilesTable.module)
            """
        case .symbolSelectBase:
            """
            SELECT s.\(SymbolsTable.id), s.\(SymbolsTable.fileID), f.\(FilesTable.path), f.\(FilesTable.module), s.\(SymbolsTable.parentID), s.\(SymbolsTable.kind), s.\(SymbolsTable.symbolName), s.\(SymbolsTable.line), s.\(SymbolsTable.column), s.\(SymbolsTable.endLine),
                   s.\(SymbolsTable.access), s.\(SymbolsTable.isStatic), s.\(SymbolsTable.isStored), s.\(SymbolsTable.signature), s.\(SymbolsTable.docSummary), s.\(SymbolsTable.ifConfig), s.\(SymbolsTable.viewOutline)
            FROM \(SymbolsTable.name) s JOIN \(FilesTable.name) f ON f.\(FilesTable.id) = s.\(SymbolsTable.fileID)
            """
        case .extensionsClause:
            "WHERE s.\(SymbolsTable.kind) = 'extension' AND (s.\(SymbolsTable.symbolName) = ? OR s.\(SymbolsTable.symbolName) LIKE '%.' || ? ESCAPE '\\')"
        case .specializedExtensionsClause:
            "WHERE s.\(SymbolsTable.kind) = 'extension' AND (s.\(SymbolsTable.symbolName) GLOB ?1 || '<*' OR s.\(SymbolsTable.symbolName) GLOB '*.' || ?1 || '<*')"
        case .sugaredExtensionsClause:
            "WHERE s.\(SymbolsTable.kind) = 'extension' AND (substr(s.\(SymbolsTable.symbolName), 1, 1) = '[' OR substr(s.\(SymbolsTable.symbolName), -1) = '?')"
        case .childrenClause: "WHERE s.\(SymbolsTable.parentID) = ?"
        case .symbolByIDClause: "WHERE s.\(SymbolsTable.id) = ?"
        case .symbolsNamedClause:
            "WHERE s.\(SymbolsTable.symbolName) = ?1 OR (s.\(SymbolsTable.symbolName) >= ?1 || '(' AND s.\(SymbolsTable.symbolName) < ?1 || ')')"
        case .conformersClause:
            "WHERE s.\(SymbolsTable.id) IN (SELECT \(InheritedTable.symbolID) FROM \(InheritedTable.name) WHERE \(InheritedTable.inheritedName) = ?1 OR (\(InheritedTable.inheritedName) >= ?1 || '<' AND \(InheritedTable.inheritedName) < ?1 || '=') OR \(InheritedTable.inheritedName) GLOB '*.' || ?1 OR \(InheritedTable.inheritedName) GLOB '*.' || ?1 || '<*')"
        case .conformerCandidatesClause:
            StoreStatement.conformersClause.sql
                + " OR s.\(SymbolsTable.id) IN (SELECT \(InheritedTable.symbolID) FROM \(InheritedTable.name) WHERE instr(\(InheritedTable.inheritedName), '&') > 0 AND instr(\(InheritedTable.inheritedName), ?1) > 0)"
        case .containersClause:
            "WHERE s.\(SymbolsTable.symbolName) = ? OR (s.\(SymbolsTable.kind) = 'extension' AND s.\(SymbolsTable.symbolName) LIKE '%.' || ? ESCAPE '\\')"
        case .inheritedNames:
            "SELECT \(InheritedTable.inheritedName) FROM \(InheritedTable.name) WHERE \(InheritedTable.symbolID) = ? ORDER BY \(InheritedTable.position)"
        case .childCount: "SELECT COUNT(*) FROM \(SymbolsTable.name) WHERE \(SymbolsTable.parentID) = ?"
        case .updateMtime: "UPDATE \(FilesTable.name) SET \(FilesTable.mtime) = ? WHERE \(FilesTable.path) = ?"
        case .topLevelSymbolsInFileClause: "WHERE s.\(SymbolsTable.fileID) = ? AND s.\(SymbolsTable.parentID) IS NULL"
        case .topLevelSymbolsInModuleClause: "WHERE f.\(FilesTable.module) = ? AND s.\(SymbolsTable.parentID) IS NULL"
        case .symbolsInFileClause: "WHERE f.\(FilesTable.path) = ?"
        case .everyTypealiasClause: "WHERE s.\(SymbolsTable.kind) = 'typealias'"
        case .everyMacroClause: "WHERE s.\(SymbolsTable.kind) = 'macro'"
        }
    }
}
