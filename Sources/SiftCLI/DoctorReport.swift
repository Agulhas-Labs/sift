//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// Everything `sift doctor` found: the checks of each agent it looked at, and the agents it did not find.
struct DoctorReport {
    let checks: [DoctorCheck]
    /// Each agent not detected, with what was looked for.
    let skipped: [(agent: InstallAgent, lookedFor: [String])]

    var failed: [DoctorCheck] {
        checks.filter { $0.status == .fail }
    }

    /// The verdict line, first in the answer.
    var verdict: String {
        let outcome = failed.isEmpty ? "passed" : "failed"
        var line = "doctor: \(outcome) — \(failed.count) of \(checks.count) checks failed"
        if !skipped.isEmpty {
            line += "; not detected: \(skipped.map(\.agent.harness).joined(separator: ", "))"
        }
        return line
    }

    /// The verdict, then one line per check, then one per agent skipped.
    var lines: [String] {
        [verdict] + checks.map(\.line) + skipped.map { "\($0.agent.rawValue): not detected, skipped — looked for \($0.lookedFor.joined(separator: ", "))" }
    }

    /// The same answer as one JSON object.
    var json: [String: Any] {
        [
            "verdict": failed.isEmpty ? "passed" : "failed",
            "checks": checks.map(\.json),
            "skipped": skipped.map { ["agent": $0.agent.rawValue, "lookedFor": $0.lookedFor] as [String: Any] },
        ]
    }
}
