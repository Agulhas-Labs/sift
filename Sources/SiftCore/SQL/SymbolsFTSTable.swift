//
// Copyright © Agulhas Labs
//

/// The `symbols_fts` virtual table's name and column spellings, typed once so a rename fails to compile everywhere it is read.
struct SymbolsFTSTable {
    static var name: String {
        "symbols_fts"
    }

    static var rowid: String {
        #function
    }

    static var ftsName: String {
        "name"
    }
}
