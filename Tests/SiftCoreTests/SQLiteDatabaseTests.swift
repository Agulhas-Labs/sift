//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the connection wrapper's one behaviour that is not visible from any query: what happens when it is let go of.
@Suite(.temporaryDirectories)
struct SQLiteDatabaseTests {
    /// A connection released beside a statement that is still alive must still let go of the database.
    ///
    /// `sqlite3_close` returns `SQLITE_BUSY` and leaves the connection **open** when any statement prepared on it has not been finalized, and the order ARC destroys a statement and its connection in is not something a caller gets to specify. What leaks is the lock rather than the handle: the connection stays open for the life of the process, still in whatever read transaction the statement was in, and every later writer is refused by something nothing is using. It shows as a holder that has already been released going on refusing a journal-mode change, so the change defers forever.
    @Test
    func aConnectionReleasedBesideALiveStatementStillReleasesItsLocks() throws {
        let directory = try TestSources.makeTempDirectory()
        let path = directory.appendingPathComponent("marks.db").path
        do {
            let database = try SQLiteDatabase(path: path)
            try database.execute("PRAGMA journal_mode = WAL")
            try database.execute("CREATE TABLE marks (id INTEGER PRIMARY KEY)")
        }

        // Two optionals released in a stated order, connection first, because that ordering *is* the
        // case under test. Held in one tuple the order is ARC's to choose, and the choice it is free to
        // make either way includes finalizing the statement first — which is the arrangement `sqlite3_close`
        // also survives, so on any toolchain that picks it this test would pass while proving nothing.
        var reading: SQLiteStatement?
        var database: SQLiteDatabase? = try SQLiteDatabase(path: path)
        reading = try database?.prepare("SELECT COUNT(*) FROM marks")
        _ = try reading?.step()
        database = nil
        reading = nil
        #expect(database == nil)
        #expect(reading == nil)

        // A journal-mode change is refused outright by any live reader, which makes it the sharpest
        // available test of whether this database is really free.
        let writer = try SQLiteDatabase(path: path)
        try writer.execute("PRAGMA busy_timeout = 250")
        let mode = try writer.prepare("PRAGMA journal_mode = DELETE")

        #expect(try mode.step())
        #expect(mode.columnText(0) == "delete")
    }
}
