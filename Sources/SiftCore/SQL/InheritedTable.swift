//
// Copyright © Agulhas Labs
//

/// The `inherited` table's name and column spellings, typed once so a rename fails to compile everywhere it is read.
struct InheritedTable {
    static var name: String {
        "inherited"
    }

    static var symbolID: String {
        "symbol_id"
    }

    static var inheritedName: String {
        "name"
    }

    static var position: String {
        #function
    }
}
