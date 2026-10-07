//
// Copyright © Agulhas Labs
//

/// The `files` table's name and column spellings, typed once so a rename fails to compile everywhere it is read.
struct FilesTable {
    static var name: String {
        "files"
    }

    static var id: String {
        #function
    }

    static var path: String {
        #function
    }

    static var mtime: String {
        #function
    }

    static var size: String {
        #function
    }

    static var contentHash: String {
        "content_hash"
    }

    static var module: String {
        #function
    }

    static var moduleGuessed: String {
        "module_guessed"
    }

    static var imports: String {
        #function
    }

    static var parseErrorCount: String {
        "parse_error_count"
    }
}
