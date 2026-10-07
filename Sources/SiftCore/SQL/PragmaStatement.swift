//
// Copyright © Agulhas Labs
//

/// Every fixed `PRAGMA` the store, its schema and its read-only probe run, named once so each is greppable from here.
enum PragmaStatement {
    case foreignKeysOn
    case busyTimeout5000
    case busyTimeout1000
    case userVersionRead
    case userVersionWrite(Int32)
    case journalSizeLimit
    case autoVacuumIncremental
    case journalModeWAL
    case synchronousNormal
    case incrementalVacuum
    case walCheckpointTruncate

    var sql: String {
        switch self {
        case .foreignKeysOn: "PRAGMA foreign_keys = ON"
        case .busyTimeout5000: "PRAGMA busy_timeout = 5000"
        case .busyTimeout1000: "PRAGMA busy_timeout = 1000"
        case .userVersionRead: "PRAGMA user_version"
        case let .userVersionWrite(version): "PRAGMA user_version = \(version)"
        case .journalSizeLimit: "PRAGMA journal_size_limit = 33554432"
        case .autoVacuumIncremental: "PRAGMA auto_vacuum = INCREMENTAL"
        case .journalModeWAL: "PRAGMA journal_mode = WAL"
        case .synchronousNormal: "PRAGMA synchronous = NORMAL"
        case .incrementalVacuum: "PRAGMA incremental_vacuum"
        case .walCheckpointTruncate: "PRAGMA wal_checkpoint(TRUNCATE)"
        }
    }
}
