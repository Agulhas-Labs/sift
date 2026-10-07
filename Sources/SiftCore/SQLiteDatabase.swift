//
// Copyright © Agulhas Labs
//

import Foundation
import SQLite3

/// A thin connection wrapper over the system SQLite: open, exec, prepare, transactions.
///
/// Every connection sets `foreign_keys = ON` at open — SQLite defaults it off, and without it every `ON DELETE CASCADE` in the schema is a no-op (Docs/Design.md §6.1).
final class SQLiteDatabase {
    private(set) var handle: OpaquePointer?

    /// Opens (or creates) the database at `path`; `beforeSchema` pragmas that must precede table creation are the caller's job via `execute`.
    init(path: String) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open(path, &pointer) == SQLITE_OK else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(pointer)
            throw SQLiteError("open failed: \(message)")
        }
        handle = pointer
        try execute(PragmaStatement.foreignKeysOn.sql)
        try execute(PragmaStatement.busyTimeout5000.sql)
    }

    /// Opens an existing database strictly read-only — for probing *another* repository's index, which must never be created, migrated, or otherwise written by the probing process.
    init(readOnlyPath path: String) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(path, &pointer, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(pointer)
            throw SQLiteError("read-only open failed: \(message)")
        }
        handle = pointer
        try execute(PragmaStatement.busyTimeout1000.sql)
    }

    /// Closed with `sqlite3_close_v2`, which is the only one of the two that always closes.
    ///
    /// `sqlite3_close` returns `SQLITE_BUSY` and leaves the connection **open** when any statement prepared on it has not been finalized — and a caller cannot generally guarantee that ordering, because a statement and its connection released together are destroyed in whatever order ARC picks. The consequence is not a leaked handle so much as a leaked *lock*: the connection stays open for the life of the process, still holding whatever read transaction the statement was in, and every later writer sees `database is locked` from something nothing is using — a holder already released goes on refusing a journal-mode change, so the change defers forever. `close_v2` marks the connection a zombie and closes it when the last statement goes.
    deinit {
        sqlite3_close_v2(handle)
    }

    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            throw SQLiteError("exec failed: \(text) — \(sql.prefix(80))")
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError("prepare failed: \(String(cString: sqlite3_errmsg(handle))) — \(sql.prefix(80))")
        }
        return SQLiteStatement(statement: statement)
    }

    var lastInsertRowID: Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    func inTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute(TransactionStatement.begin.sql)
        do {
            let result = try body()
            try execute(TransactionStatement.commit.sql)
            return result
        } catch {
            try? execute(TransactionStatement.rollback.sql)
            throw error
        }
    }
}
