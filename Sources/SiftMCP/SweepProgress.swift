//
// Copyright © Agulhas Labs
//

import Foundation

/// What a transcript sweep tells its caller while it runs: that it began and over how many sessions, how far it has got every fifty, and that it finished.
struct SweepProgress {
    let tell: (String) -> Void

    func began(_ sessions: Int) {
        tell("scanning \(sessions) session transcripts (each with its subagents) for Swift lookups; this reads every line of them and can take minutes")
    }

    func reached(_ index: Int, of sessions: Int) {
        guard index > 0, index % 50 == 0 else { return }
        tell("scanned \(index) of \(sessions) session transcripts")
    }

    func finished(_ sessions: Int) {
        tell("scanned \(sessions) of \(sessions) session transcripts")
    }
}
