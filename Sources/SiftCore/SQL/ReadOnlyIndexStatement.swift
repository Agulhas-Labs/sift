//
// Copyright © Agulhas Labs
//

/// Every statement `ReadOnlyIndex` runs against another repository's store.
enum ReadOnlyIndexStatement {
    case beginSnapshot
    case fileAndGuessedModuleCounts
    case fileCount
    case indexedHead

    var sql: String {
        switch self {
        case .beginSnapshot: "BEGIN DEFERRED"
        case .fileAndGuessedModuleCounts: "SELECT COUNT(*), SUM(\(FilesTable.moduleGuessed)) FROM \(FilesTable.name)"
        case .fileCount: "SELECT COUNT(*) FROM \(FilesTable.name)"
        case .indexedHead: "SELECT \(MetaTable.value) FROM \(MetaTable.name) WHERE \(MetaTable.key) = 'indexed_head'"
        }
    }
}
