//
// Copyright © Agulhas Labs
//

/// A failed SQLite operation, carrying the library's own message.
public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let description: String

    init(_ description: String) {
        self.description = description
    }
}
