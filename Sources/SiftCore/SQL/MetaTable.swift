//
// Copyright © Agulhas Labs
//

/// The `meta` table's name and column spellings, typed once so a rename fails to compile everywhere it is read.
struct MetaTable {
    static var name: String {
        "meta"
    }

    static var key: String {
        #function
    }

    static var value: String {
        #function
    }
}
