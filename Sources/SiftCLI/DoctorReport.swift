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
    /// Each agent found with nothing of sift's in it, which is said and not counted; the run fails only when every agent found is one (``nothingInstalled``).
    var notInstalled: [InstallAgent] = []

    var failed: [DoctorCheck] {
        checks.filter { $0.status == .fail }
    }

    /// Whether agents were found and none has sift installed, so there is nothing for doctor to pass.
    var nothingInstalled: Bool {
        checks.isEmpty && !notInstalled.isEmpty
    }

    /// Whether the answer is a failure: a check failed, or no agent found has sift installed.
    var failsTheRun: Bool {
        !failed.isEmpty || nothingInstalled
    }

    /// The verdict line, first in the answer.
    var verdict: String {
        if nothingInstalled {
            return "doctor: failed — no agent has sift installed; `sift install` adds it"
        }
        let outcome = failed.isEmpty ? "passed" : "failed"
        var line = "doctor: \(outcome) — \(failed.count) of \(checks.count) checks failed"
        if !skipped.isEmpty {
            line += "; not detected: \(skipped.map(\.agent.harness).joined(separator: ", "))"
        }
        return line
    }

    /// The verdict, then one line per check, then one per agent found without sift, then one per agent skipped.
    var lines: [String] {
        [verdict] + checks.map(\.line) + notInstalled.map { "\($0.rawValue): found, sift not installed — sift install --agent \($0.rawValue) adds it" } + skipped.map { "\($0.agent.rawValue): not detected, skipped — looked for \($0.lookedFor.joined(separator: ", "))" }
    }

    /// The same answer as one JSON object.
    var json: [String: Any] {
        [
            "verdict": failsTheRun ? "failed" : "passed",
            "checks": checks.map(\.json),
            "notInstalled": notInstalled.map(\.rawValue),
            "skipped": skipped.map { ["agent": $0.agent.rawValue, "lookedFor": $0.lookedFor] as [String: Any] },
        ]
    }
}
