//
// Copyright © Agulhas Labs
//

/// Every statement `SiblingIndexProbe` runs against another repository's store.
enum SiblingProbeStatement {
    case declaresName
    case extendsName
    case recordsPath
    case candidatesByLastComponentWithPath
    case candidatesByLastComponent
    case enclosingNames

    var sql: String {
        switch self {
        case .declaresName:
            "SELECT 1 FROM \(SymbolsTable.name) WHERE (\(SymbolsTable.symbolName) = ?1 OR (\(SymbolsTable.symbolName) >= ?1 || '(' AND \(SymbolsTable.symbolName) < ?1 || ')')) AND \(SymbolsTable.kind) != 'extension' LIMIT 1"
        case .extendsName:
            "SELECT 1 FROM \(SymbolsTable.name) WHERE \(SymbolsTable.symbolName) = ?1 AND \(SymbolsTable.kind) = 'extension' LIMIT 1"
        case .recordsPath: "SELECT 1 FROM \(FilesTable.name) WHERE \(FilesTable.path) = ? LIMIT 1"
        case .candidatesByLastComponent:
            """
            SELECT s.\(SymbolsTable.id), f.\(FilesTable.module) FROM \(SymbolsTable.name) s JOIN \(FilesTable.name) f ON f.\(FilesTable.id) = s.\(SymbolsTable.fileID)
            WHERE (s.\(SymbolsTable.symbolName) = ?1 OR (s.\(SymbolsTable.symbolName) >= ?1 || '(' AND s.\(SymbolsTable.symbolName) < ?1 || ')')) AND s.\(SymbolsTable.kind) != 'extension'
            """
        case .candidatesByLastComponentWithPath:
            """
            SELECT s.\(SymbolsTable.id), f.\(FilesTable.path), f.\(FilesTable.module) FROM \(SymbolsTable.name) s JOIN \(FilesTable.name) f ON f.\(FilesTable.id) = s.\(SymbolsTable.fileID)
            WHERE (s.\(SymbolsTable.symbolName) = ?1 OR (s.\(SymbolsTable.symbolName) >= ?1 || '(' AND s.\(SymbolsTable.symbolName) < ?1 || ')')) AND s.\(SymbolsTable.kind) != 'extension'
            """
        case .enclosingNames:
            "SELECT \(SymbolsTable.symbolName), \(SymbolsTable.parentID) FROM \(SymbolsTable.name) WHERE \(SymbolsTable.id) = ?"
        }
    }
}
