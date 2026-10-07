//
// Copyright © Agulhas Labs
//

/// The `symbols` table's name and column spellings, typed once so a rename fails to compile everywhere it is read.
struct SymbolsTable {
    static var name: String {
        "symbols"
    }

    static var id: String {
        #function
    }

    static var fileID: String {
        "file_id"
    }

    static var parentID: String {
        "parent_id"
    }

    static var kind: String {
        #function
    }

    static var symbolName: String {
        "name"
    }

    static var line: String {
        #function
    }

    static var column: String {
        #function
    }

    static var endLine: String {
        "end_line"
    }

    static var access: String {
        #function
    }

    static var isStatic: String {
        "is_static"
    }

    static var isStored: String {
        "is_stored"
    }

    static var signature: String {
        #function
    }

    static var docSummary: String {
        "doc_summary"
    }

    static var ifConfig: String {
        "if_config"
    }

    static var viewOutline: String {
        "view_outline"
    }
}
