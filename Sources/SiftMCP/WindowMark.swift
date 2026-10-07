//
// Copyright © Agulhas Labs
//

import Foundation

/// What a result line for one call finds before it is read, so ``ScanWindowLog`` can settle what that result did once it has been: the call and its tool, what was located and digested already, and how many events the line had produced.
struct WindowMark {
    let call: String
    let tool: String
    let located: [String: Set<String>]
    let digests: [String: Set<LocatedDigest>]
    let events: Int
}
