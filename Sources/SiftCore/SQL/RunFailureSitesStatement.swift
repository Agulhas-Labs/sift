//
// Copyright © Agulhas Labs
//

/// The one statement `RunFailureSites` runs against the index.
enum RunFailureSitesStatement {
    case allPaths

    var sql: String {
        switch self {
        case .allPaths: "SELECT \(FilesTable.path) FROM \(FilesTable.name)"
        }
    }
}
