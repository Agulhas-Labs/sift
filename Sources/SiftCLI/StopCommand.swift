//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
import SiftCore
import SiftMCP

/// `sift stop` — the body of the Claude Code `Stop` and `SubagentStop` hooks, run when a context is about to end its turn.
///
/// One command for both events, reading which one fired from the payload's `hook_event_name`. It holds to the other hooks' invariants: it always exits 0, prints nothing unless it blocks, and gives up in silence past its budget.
struct StopCommand: ParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "stop",
            abstract: "Send a context that edited Swift back to build it before it stops (Stop and SubagentStop hook).",
            discussion: """
            Reads the hook's payload on stdin. When the stopping context — the session, or the subagent for SubagentStop — made a successful Write, Edit or MultiEdit of a .swift file since its last green `sift run` build or test, and no green sift run is on record for the repository's tree as it stands (the record `sift run --proved` reads), it blocks the stop once with the command to run, always a build: `sift run -- swift build` where a Package.swift sits at the root, else the `sift run -- xcodebuild … build` command the context already ran, as it wrote it. A `sift run` of that same tree still going (a progress file under .sift/progress/ with a heartbeat under 5 s old) lets the stop through; one of an earlier tree makes the block say to run again once it ends.

            Otherwise silent: for a context that edited no Swift, with stop_hook_active set, a second time for the same context and tree, where no command can be named, past a one-second budget, and on any error. SIFT_NO_ADVICE turns it off, as it does the other hooks.
            """
        )
    }

    func run() {
        let disabled = ProcessInfo.processInfo.environment["SIFT_NO_ADVICE"] ?? ""
        guard disabled.isEmpty else { return }
        let payload = Self.hookPayload()
        guard !CursorHookPayload.recognises(payload) else { return }
        Self.answer(to: payload)
    }

    /// Everything the hook does with one payload: the block, printed to `output`, or nothing.
    ///
    /// Judged off the calling thread and waited on for `timeBudget` at most, so a slow git or a huge transcript lets the stop go through rather than holding the session.
    ///
    /// One ``RootDiscovery`` serves the whole judgement — the one the caller bound, else a fresh one — so the transcript's reading and the repositories it names ask git about each directory once between them, rather than once per directory and again per file.
    static func answer(to payload: [String: Any], output: CommandOutput = .standard, marks: ReuseNudgeMarks = .standard(), timeBudget: TimeInterval = StopBuildGate.timeBudget, now: Date = Date()) {
        let input = ResultBox<[String: Any]>()
        input.value = payload
        let result = ResultBox<String>()
        let finished = DispatchSemaphore(value: 0)
        // A task-local does not cross onto a dispatch queue, so the discovery is carried across by hand.
        let roots = RootDiscovery.current ?? RootDiscovery()
        DispatchQueue.global().async {
            result.value = RootDiscovery.$current.withValue(roots) {
                input.value.flatMap { StopBuildGate.reason(for: $0, marks: marks, now: now) }
            }
            finished.signal()
        }
        guard finished.wait(timeout: .now() + timeBudget) == .success,
              let reason = result.value,
              let json = HookOutput.stopBlock(reason: reason)
        else {
            return
        }
        output.emit(json)
    }

    /// The `Stop` or `SubagentStop` payload Claude Code writes to the hook's stdin.
    ///
    /// Guarded by `isatty` so running this by hand returns immediately instead of blocking on a read that will never be satisfied.
    private static func hookPayload() -> [String: Any] {
        guard isatty(FileHandle.standardInput.fileDescriptor) == 0,
              let data = try? FileHandle.standardInput.readToEnd(), !data.isEmpty,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return payload
    }
}
