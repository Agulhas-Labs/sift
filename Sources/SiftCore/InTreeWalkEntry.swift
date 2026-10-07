//
// Copyright © Agulhas Labs
//

import Foundation

/// A directory ``InTreeStoreWalk`` has yet to visit: its repo-relative path, how many levels below its ignored directory it sits, and its modification date as its parent's listing read it.
struct InTreeWalkEntry {
    let path: String
    let level: Int
    let modified: Date?
}
