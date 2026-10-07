//
// Copyright © Agulhas Labs
//

/// The three statements `SQLiteDatabase.inTransaction` wraps a write in.
enum TransactionStatement {
    case begin
    case commit
    case rollback

    var sql: String {
        switch self {
        case .begin: "BEGIN IMMEDIATE"
        case .commit: "COMMIT"
        case .rollback: "ROLLBACK"
        }
    }
}
