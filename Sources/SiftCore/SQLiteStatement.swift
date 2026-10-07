//
// Copyright © Agulhas Labs
//

import Foundation
import SQLite3

/// A prepared statement: bind by position, step, read columns, reset for reuse.
final class SQLiteStatement {
    private let statement: OpaquePointer?
    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(statement: OpaquePointer?) {
        self.statement = statement
    }

    deinit {
        sqlite3_finalize(statement)
    }

    @discardableResult
    func bind(_ index: Int32, _ value: String) -> SQLiteStatement {
        sqlite3_bind_text(statement, index, value, -1, Self.transientDestructor)
        return self
    }

    @discardableResult
    func bind(_ index: Int32, _ value: Int64) -> SQLiteStatement {
        sqlite3_bind_int64(statement, index, value)
        return self
    }

    @discardableResult
    func bind(_ index: Int32, _ value: Double) -> SQLiteStatement {
        sqlite3_bind_double(statement, index, value)
        return self
    }

    @discardableResult
    func bindNull(_ index: Int32) -> SQLiteStatement {
        sqlite3_bind_null(statement, index)
        return self
    }

    @discardableResult
    func bindOptional(_ index: Int32, _ value: String?) -> SQLiteStatement {
        if let value {
            return bind(index, value)
        }
        return bindNull(index)
    }

    /// Steps once; `true` when a row is available, `false` on done.
    func step() throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        // The result code alone ("code 10") tells a caller nothing it can act on; SQLite's own text for it ("disk I/O error") at least names the class of fault.
        case let code: throw SQLiteError("step failed: \(String(cString: sqlite3_errstr(code))) (code \(code))")
        }
    }

    /// Steps to completion for statements that return no rows.
    func run() throws {
        while try step() {}
    }

    func reset() {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    func columnIsNull(_ index: Int32) -> Bool {
        sqlite3_column_type(statement, index) == SQLITE_NULL
    }

    func columnText(_ index: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: cString)
    }

    func columnOptionalText(_ index: Int32) -> String? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : columnText(index)
    }

    func columnInt(_ index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    func columnDouble(_ index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }
}
