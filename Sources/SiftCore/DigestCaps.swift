//
// Copyright © Agulhas Labs
//

import Foundation

/// The limits every digest view pages and cuts its answer by: members per page, a member body's lines, and the view outlines one answer may carry.
struct DigestCaps {
    /// Member lines per page; enum case packs and headings don't count (Docs/Design.md §3).
    static var memberCap: Int {
        60
    }

    /// Source lines served for a member body before truncating — a guard against a 500-line function undoing the saving the tool exists for.
    static var bodyLineCap: Int {
        200
    }

    /// View-outline lines a single digest may carry, across every member in it.
    ///
    /// `paginate` budgets one *member* line per member, so without this a type with a dozen `some View` methods could render twelve forty-line outlines and never trip the page cap — a digest larger than the file it summarises, which is the failure the tool exists to prevent. The per-member limit in `ViewOutline` bounds one member; this bounds the answer.
    static var outlineCap: Int {
        120
    }
}
