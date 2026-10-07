//
// Copyright © Agulhas Labs
//

import Foundation

/// How `sift install` asks, once per detected agent, whether to install into it: the default is yes, and the end of input is no to that agent and every one after it.
///
/// The question goes through an injected `ask`, so the CLI passes its terminal and a test stands in for the person at it.
public struct InstallPrompt: Sendable {
    /// Writes the question and reads one line of answer, `nil` at the end of input.
    public let ask: @Sendable (String) -> String?

    public init(ask: @escaping @Sendable (String) -> String?) {
        self.ask = ask
    }

    /// The question for `agent`.
    public static func question(_ agent: InstallAgent) -> String {
        "Install sift into \(agent.harness)? [Y/n] "
    }

    /// The question asked again after an answer that was neither yes nor no.
    public static func retry(_ agent: InstallAgent) -> String {
        "Please answer y or n. Install sift into \(agent.harness)? [Y/n] "
    }

    /// Asks about each of `agents` in turn and returns the ones accepted, in order: an unclear answer is asked again once and then taken as no, and the end of input declines the rest unasked.
    public func choose(_ agents: [InstallAgent]) -> [InstallAgent] {
        var accepted: [InstallAgent] = []
        for agent in agents {
            var answer = Self.answer(ask(Self.question(agent)))
            if answer == .unclear {
                answer = Self.answer(ask(Self.retry(agent)))
            }
            switch answer {
            case .accept:
                accepted.append(agent)
            case .decline, .unclear:
                continue
            case .ended:
                return accepted
            }
        }
        return accepted
    }

    /// What one line of answer says: empty or `y`/`yes` in any case is `accept`, `n`/`no` is `decline`, the end of input is `ended`, anything else is unclear.
    public static func answer(_ line: String?) -> Answer {
        guard let line else { return .ended }
        return switch line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "y", "yes":
            .accept
        case "n", "no":
            .decline
        default:
            .unclear
        }
    }
}

public extension InstallPrompt {
    /// One answer, read.
    enum Answer: Equatable, Sendable {
        case accept
        case decline
        /// Neither yes nor no.
        case unclear
        /// The end of input: no one is there to answer.
        case ended
    }
}
