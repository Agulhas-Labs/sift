//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
import SiftCore
import SiftMCP

/// `sift replay-hook` — one call put to the hook `audit --replay` runs in-process, against state kept in a directory the caller names, so another build's `audit --replay --against` can put the calls of its own replay to this build's hook.
///
/// The payload is read from stdin, as the live hook reads it. The answer is one JSON object: the verdict (`hooked` false for a tool the hook is not registered for), nothing for `--answered`, or whether a file is located only by answers given in place for `--located`. `--show` prints the answer text after the verdict, where the verdict names one — the same bytes the live hook writes into `permissionDecisionReason` — so a reviewer can check it covers exactly what the real command would have printed.
struct ReplayHookCommand: ParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "replay-hook",
            abstract: "Judge one call as `audit --replay` judges it, against the replay state in --state (for `audit --replay --against`).",
            shouldDisplay: false
        )
    }

    @Option(name: .customLong("state"), help: "The directory the replay's ledger, usage log and back-off live in, kept by the caller for the whole replay.")
    var state: String

    @Option(name: .customLong("cwd"), help: "The directory the call ran in, already mapped to one on disk.")
    var cwd: String

    @Option(name: .customLong("at"), help: "The call's instant, in seconds since 1970: the clock the ledger's and the back-off's windows are measured against.")
    var instant: Double?

    @Option(name: .customLong("time-budget"), help: "The in-place answerer's time budget, in seconds.")
    var timeBudget: Double = HookReplay.timeBudget

    @Flag(name: .customLong("outside-window"), help: "Judge the call for the state it leaves, as a call before --since is judged, and answer outsideWindow.")
    var outside = false

    @Flag(name: .customLong("answered"), help: "Record that this index call came back answered, instead of judging it.")
    var answered = false

    @Option(name: .customLong("located"), help: "Answer whether this file is located only by answers given in place, instead of judging the call.")
    var located: String?

    @Flag(name: .customLong("show"), help: "After the verdict, print the answer text the hook would hand the agent as its denial reason — the same bytes `sift pre-tool-use` writes into `permissionDecisionReason` — where the verdict names one.")
    var show = false

    var output: CommandOutput = .standard

    func validate() throws {
        if show, answered {
            throw ValidationError("--show prints the verdict's answer text, which --answered doesn't judge for: drop --show or --answered.")
        }
        if show, located != nil {
            throw ValidationError("--show prints the verdict's answer text, which --located doesn't judge for: drop --show or --located.")
        }
    }

    func run() throws {
        let data = try FileHandle.standardInput.readToEnd() ?? Data()
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ValidationError("replay-hook reads one call's payload, a JSON object, from stdin.")
        }
        let directory = URL(fileURLWithPath: state, isDirectory: true)
        guard !Self.isLive(directory) else {
            throw ValidationError("--state \(state) is where the live hook keeps its ledger, usage log and back-off, which a replay would write into: name a directory of its own.")
        }
        let hook = HookReplay(directory: directory, timeBudget: timeBudget, writesSuppressions: true)
        let moment = instant.map { Date(timeIntervalSince1970: $0) }
        let answer: [String: Any]
        var reason: String?
        if answered {
            hook.answered(payload: payload, cwd: cwd, at: moment)
            answer = [:]
        } else if let located {
            answer = ["located": hook.locatedOnlyByAnswers(located, payload: payload)]
        } else if let verdict = hook.verdict(payload: payload, cwd: cwd, at: moment, decides: !outside) {
            var fields: [String: Any] = ["hooked": true, "token": verdict.token, "rule": verdict.rule]
            fields["call"] = verdict.call
            fields["answerBytes"] = verdict.answerBytes
            answer = fields
            reason = verdict.reason
        } else {
            answer = ["hooked": false]
        }
        let line = try JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys])
        output.emit(String(bytes: line, encoding: .utf8) ?? "{}")
        if show, let reason {
            output.emit("--- answer ---")
            output.emit(reason)
        }
    }
}

extension ReplayHookCommand {
    /// Whether `directory`, its symlinks resolved, is one the live hook keeps its state in: sift's home, or the parent of the advice directory the environment names.
    static func isLive(_ directory: URL) -> Bool {
        let live = [SiftPaths.home, AdviceLedger.standardDirectory().deletingLastPathComponent()].map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        return live.contains(directory.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    /// Only the flags and options come off the command line, for the reason ``AuditCommand``'s keys give.
    enum CodingKeys: String, CodingKey {
        case state
        case cwd
        case instant
        case timeBudget
        case outside
        case answered
        case located
        case show
    }
}
