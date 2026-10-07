//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP

/// A hook that lets every call through as `noLookup` and records the command of each call it was asked to judge, so a test can see which calls a replay put to it.
///
/// Built with `indexCalls`, it takes every call as an index call instead, and records the answer text the replay hands it with each one answered.
final class RecordingHook: ReplayHook {
    private(set) var judged: [String] = []
    /// The answer texts handed over with the calls answered, in order.
    private(set) var answers: [String] = []
    private let indexCalls: Bool

    init(indexCalls: Bool = false) {
        self.indexCalls = indexCalls
    }

    func verdict(payload: [String: Any], cwd _: String, at _: Date?, decides _: Bool) -> ReplayVerdict? {
        judged.append((payload["tool_input"] as? [String: Any])?["command"] as? String ?? "")
        return ReplayVerdict(token: "allowed", rule: indexCalls ? ReplayVerdict.indexCallRule : "noLookup")
    }

    func answered(payload: [String: Any], cwd _: String, at _: Date?) {
        answers.append(payload[TranscriptReplay.answerKey] as? String ?? "")
    }

    func locatedOnlyByAnswers(_: String, payload _: [String: Any]) -> Bool {
        false
    }
}
