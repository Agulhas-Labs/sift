//
// Copyright © Agulhas Labs
//

import Foundation
import SiftMCP

/// A replay hook whose every call is one unit of work of the run's interruptions, so a signal's cleanup removes the scratch only once no call can write into it again.
struct InterruptibleReplayHook: ReplayHook {
    let hook: any ReplayHook
    let interruptions: ReplayInterruptions

    func verdict(payload: [String: Any], cwd: String, at instant: Date?, decides: Bool) -> ReplayVerdict? {
        interruptions.working { hook.verdict(payload: payload, cwd: cwd, at: instant, decides: decides) }
    }

    func answered(payload: [String: Any], cwd: String, at instant: Date?) {
        interruptions.working { hook.answered(payload: payload, cwd: cwd, at: instant) }
    }

    func locatedOnlyByAnswers(_ path: String, payload: [String: Any]) -> Bool {
        interruptions.working { hook.locatedOnlyByAnswers(path, payload: payload) }
    }
}
