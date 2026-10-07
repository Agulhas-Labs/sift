//
// Copyright © Agulhas Labs
//

import Foundation

/// Who a context's calls are made by, where a line does not say.
struct ReplayIdentity {
    let sessionTranscript: String
    let fallbackSession: String
    let fallbackAgent: String?
}
