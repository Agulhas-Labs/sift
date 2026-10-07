//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
import SiftCore

/// What one agent's step of `sift install` did: the lines its installers printed, the files it wrote, whether it registered a server, and what failed.
struct InstallStepReport: Equatable {
    let agent: InstallAgent
    /// Every line the step's installers printed, in order.
    var lines: [String] = []
    /// Each file the step rewrote, as the installers name it.
    var written: [String] = []
    /// Whether the step registered or repointed an MCP server through the agent's own command, which writes a file this tool does not name.
    var registered = false
    /// What the step set out to do and could not, one line each: any one makes `sift install` exit 1.
    var failures: [String] = []

    /// Whether the step changed anything.
    var changed: Bool {
        !written.isEmpty || registered
    }

    /// Runs `step` for `agent` with its lines going to `capture`, turning anything it throws into a failure of this agent alone, so the agents after it still run.
    static func attempt(_ agent: InstallAgent, capture: InstallCapture, _ step: () throws -> InstallStepReport) -> InstallStepReport {
        var report: InstallStepReport
        var thrown = true
        do {
            report = try step()
            thrown = false
        } catch let exit as ExitCode {
            report = InstallStepReport(agent: agent, failures: ["stopped with exit status \(exit.rawValue)"])
        } catch {
            // A refusal (`CursorInstall.Refused`, `SettingsFile.Unwritten`, `HookRegistrationError`) describes itself with the path and what to do.
            report = InstallStepReport(agent: agent, failures: [String(describing: error)])
        }
        report.lines = capture.lines
        // A failure the step returns was printed by its installer already; one it threw was not, and is said under the agent's header here.
        report.lines += thrown ? report.failures : []
        return report
    }
}
