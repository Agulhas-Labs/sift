//
// Copyright © Agulhas Labs
//

/// Every `DROP`/`CREATE` `IndexSchema` runs, built from the table and column constants so a renamed table or column fails to compile here rather than at runtime.
enum SchemaDDLStatement {
    case dropInherited
    case dropSymbolsFTS
    case dropSymbols
    case dropFiles
    case dropMeta
    case createMeta
    case createFiles
    case createSymbols
    case createInherited
    case indexSymbolsName
    case indexSymbolsFile
    case indexSymbolsParent
    case indexInheritedName
    case indexInheritedSymbol
    case indexFilesModule
    case createSymbolsFTS

    var sql: String {
        switch self {
        case .dropInherited: "DROP TABLE IF EXISTS \(InheritedTable.name)"
        case .dropSymbolsFTS: "DROP TABLE IF EXISTS \(SymbolsFTSTable.name)"
        case .dropSymbols: "DROP TABLE IF EXISTS \(SymbolsTable.name)"
        case .dropFiles: "DROP TABLE IF EXISTS \(FilesTable.name)"
        case .dropMeta: "DROP TABLE IF EXISTS \(MetaTable.name)"
        case .createMeta:
            """
            CREATE TABLE IF NOT EXISTS \(MetaTable.name)(
                \(MetaTable.key) TEXT PRIMARY KEY,
                \(MetaTable.value) TEXT NOT NULL
            )
            """
        case .createFiles:
            """
            CREATE TABLE IF NOT EXISTS \(FilesTable.name)(
                \(FilesTable.id) INTEGER PRIMARY KEY,
                \(FilesTable.path) TEXT NOT NULL UNIQUE,
                \(FilesTable.mtime) REAL NOT NULL,
                \(FilesTable.size) INTEGER NOT NULL,
                \(FilesTable.contentHash) TEXT NOT NULL,
                \(FilesTable.module) TEXT NOT NULL,
                \(FilesTable.moduleGuessed) INTEGER NOT NULL,
                \(FilesTable.imports) TEXT NOT NULL,
                \(FilesTable.parseErrorCount) INTEGER NOT NULL
            )
            """
        case .createSymbols:
            """
            CREATE TABLE IF NOT EXISTS \(SymbolsTable.name)(
                \(SymbolsTable.id) INTEGER PRIMARY KEY,
                \(SymbolsTable.fileID) INTEGER NOT NULL REFERENCES \(FilesTable.name)(\(FilesTable.id)) ON DELETE CASCADE,
                \(SymbolsTable.parentID) INTEGER,
                \(SymbolsTable.kind) TEXT NOT NULL,
                \(SymbolsTable.symbolName) TEXT NOT NULL,
                \(SymbolsTable.line) INTEGER NOT NULL,
                \(SymbolsTable.column) INTEGER NOT NULL,
                \(SymbolsTable.endLine) INTEGER NOT NULL,
                \(SymbolsTable.access) TEXT NOT NULL,
                \(SymbolsTable.isStatic) INTEGER NOT NULL,
                \(SymbolsTable.isStored) INTEGER NOT NULL,
                \(SymbolsTable.signature) TEXT NOT NULL,
                \(SymbolsTable.docSummary) TEXT,
                \(SymbolsTable.ifConfig) TEXT,
                \(SymbolsTable.viewOutline) TEXT
            )
            """
        case .createInherited:
            """
            CREATE TABLE IF NOT EXISTS \(InheritedTable.name)(
                \(InheritedTable.symbolID) INTEGER NOT NULL REFERENCES \(SymbolsTable.name)(\(SymbolsTable.id)) ON DELETE CASCADE,
                \(InheritedTable.inheritedName) TEXT NOT NULL,
                \(InheritedTable.position) INTEGER NOT NULL
            )
            """
        case .indexSymbolsName: "CREATE INDEX IF NOT EXISTS idx_symbols_name ON \(SymbolsTable.name)(\(SymbolsTable.symbolName))"
        case .indexSymbolsFile: "CREATE INDEX IF NOT EXISTS idx_symbols_file ON \(SymbolsTable.name)(\(SymbolsTable.fileID))"
        case .indexSymbolsParent: "CREATE INDEX IF NOT EXISTS idx_symbols_parent ON \(SymbolsTable.name)(\(SymbolsTable.parentID))"
        case .indexInheritedName: "CREATE INDEX IF NOT EXISTS idx_inherited_name ON \(InheritedTable.name)(\(InheritedTable.inheritedName))"
        case .indexInheritedSymbol: "CREATE INDEX IF NOT EXISTS idx_inherited_symbol ON \(InheritedTable.name)(\(InheritedTable.symbolID))"
        case .indexFilesModule: "CREATE INDEX IF NOT EXISTS idx_files_module ON \(FilesTable.name)(\(FilesTable.module))"
        case .createSymbolsFTS: "CREATE VIRTUAL TABLE IF NOT EXISTS \(SymbolsFTSTable.name) USING fts5(\(SymbolsFTSTable.ftsName))"
        }
    }
}
