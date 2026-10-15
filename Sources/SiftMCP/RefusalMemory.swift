//
// Copyright © Agulhas Labs
//

import Foundation

/// What the transcript scan remembers of a refusal it reads back: the keys a lookup's identical re-run is recognised by.
struct RefusalMemory {
    /// What a whole read is remembered by once the hook has answered it in place — the key the advice ledger gives it — so its identical re-run is recognised as the escape hatch a search's is.
    static func readKey(_ path: String) -> String {
        "Read \(path)"
    }
}
