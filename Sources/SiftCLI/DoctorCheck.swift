//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// One check `sift doctor` made of one agent's install: what it checked, how it came out, and what it saw.
struct DoctorCheck: Equatable {
    let agent: InstallAgent
    /// What was checked, as the line names it: `binary`, `hook PreToolUse`, `mcp server`.
    let name: String
    let status: Status
    /// What was seen, and for a failure what to do about it.
    let detail: String

    /// The check's one line of the answer.
    var line: String {
        "\(agent.rawValue) \(name): \(status.rawValue) — \(detail)"
    }

    /// The check as `--json` carries it.
    var json: [String: Any] {
        ["agent": agent.rawValue, "check": name, "status": status.rawValue, "detail": detail, "line": line]
    }

    static func pass(_ agent: InstallAgent, _ name: String, _ detail: String) -> DoctorCheck {
        DoctorCheck(agent: agent, name: name, status: .pass, detail: detail)
    }

    static func fail(_ agent: InstallAgent, _ name: String, _ detail: String) -> DoctorCheck {
        DoctorCheck(agent: agent, name: name, status: .fail, detail: detail)
    }

    static func unknown(_ agent: InstallAgent, _ name: String, _ detail: String) -> DoctorCheck {
        DoctorCheck(agent: agent, name: name, status: .unknown, detail: detail)
    }
}

extension DoctorCheck {
    /// How a check came out: only `fail` makes `sift doctor` exit 1.
    enum Status: String {
        case pass
        case fail
        /// What the check needed could not be read; never a failure.
        case unknown
        /// Two things that could match do not, which is said and never a failure: the registered binary's version and this one's.
        case differs
    }
}
