//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// Best-effort, append-only JSONL record of index lookups — one line per call, whichever face served it.
///
/// Every face writes here: the MCP server, the advice hook answering in place, and the CLI's four query subcommands (``SiftCLI/LoggedLookup``). One binary over one engine, so a lookup holds the same numbers wherever it was asked from, and a file that held only half of them measured the tool over half its answers.
///
/// Transcript greps only cover one machine and expire with transcript cleanup; this file is the durable ground truth for whether the server earns its keep, and *what gets asked* is the signal for which parts of a codebase keep being rediscovered. Logging must never affect the protocol: every failure is swallowed after a stderr note, and nothing here writes to stdout.
///
/// **It means index lookups and nothing else.** `sift run` keeps its own file (``RunUsageLog``) rather than appending here, because the call count, the savings denominator and the audit all read this one as "lookups" and a wrapped build is not one.
///
/// The appending itself belongs to ``JSONLineLog``, shared with that log so the two cannot drift in how a failure is handled.
public struct UsageLog: Sendable {
    private let log: JSONLineLog

    public init(fileURL: URL, note: @escaping @Sendable (String) -> Void = { _ in }) {
        log = JSONLineLog(fileURL: fileURL, subject: "sift mcp: usage log", note: note)
    }

    /// The shared per-user log, `~/.sift/usage.jsonl` — one file across every root so an adoption review is a single read, not a per-repo hunt.
    public static func standard(note: @escaping @Sendable (String) -> Void = { _ in }) -> UsageLog {
        UsageLog(fileURL: standardFileURL(), note: note)
    }

    /// `~/.sift/usage.jsonl`, or the file `SIFT_USAGE_LOG` names.
    ///
    /// Narrow for the reason `SIFT_SERVER_LOG` is (``ServerLifecycleLog``): taking a session over in place is only observable from outside a running server, through real tool calls, and the test that makes them must not append to the record a person reads to decide whether the tool earns its keep. Every face honours it, writers and readers alike — the server, the hook, the CLI and `usage`, `report` and `servers` — through this one function, so a reader's "missing or empty" names the file it read and a redirected log is never reported absent for being read at the real path.
    public static func standardFileURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["SIFT_USAGE_LOG"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return SiftPaths.home(environment: environment).appendingPathComponent("usage.jsonl")
    }

    /// The log the advice hook records an in-place answer in, or `nil` where no conversation was handed that answer.
    ///
    /// Claude Code names the session's transcript in every hook payload, and that file exists by the time a tool is called. A payload naming none, or one that is not on disk, was piped in by hand to probe the hook, so a line for it in the shared log would be a saving that `usage` counts and no context had. A probe that points `SIFT_USAGE_LOG` elsewhere has chosen where its lines go, and gets them there.
    public static func forHookAnswer(
        transcriptPath: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        note: @escaping @Sendable (String) -> Void = { _ in }
    ) -> UsageLog? {
        let redirected = !(environment["SIFT_USAGE_LOG"] ?? "").isEmpty
        let delivered = transcriptPath.map { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) } ?? false
        guard redirected || delivered else { return nil }
        return UsageLog(fileURL: standardFileURL(environment: environment), note: note)
    }

    /// The conversation Claude Code puts in a process's environment, or `nil` where the binary is being run directly.
    ///
    /// Named here rather than read at each site, because two readers depend on it meaning the same thing: this log's `session` field, and the slip the `PreToolUse` hook leaves for a call under that session (``CallAttribution``). A machine running the binary by hand has no session and records none, which is exactly right — there is no conversation to attribute the call to.
    ///
    /// **Empty is absent**, on the same reading `agent` is given below, and a third reader makes that more than cosmetic: `sift servers` spares a server whose session matches the caller's, and reports when the caller has no name to match with. Read as a name, an empty variable would match no recorded session, so the guard would be inoperative *and* the report would say nothing was wrong.
    public static var currentSession: String? {
        guard let session = ProcessInfo.processInfo.environment["CLAUDE_CODE_SESSION_ID"], !session.isEmpty else { return nil }
        return session
    }

    /// Appends one line for this call; `answer` carries what was served, and the source it stands in for only where the tool read that source.
    ///
    /// **Every answered call records what it served.** That number needs no counterfactual — it is the length of what went out — and withholding it from the tools that have no denominator would score their calls as a saving of zero, which is a claim the log never made. `srcBytes` still appears only where it was measured, and never without `outBytes`: see ``AnswerBytes`` for why the halves are not symmetric.
    ///
    /// A failed call records neither. Its bytes are a refusal rather than an answer, and counting refusal text as served would pad the numerator of a figure whose whole worth is that it can be checked.
    ///
    /// **A call naming several targets records them as a list**, `targets`, in place of `target`: each is a name the codebase was asked about, and one string joining them is a name nobody asked for. A line with one target is written exactly as before, so every reader that only knows `target` reads it unchanged.
    ///
    /// `session` defaults to the one in this process's environment, which is the server's; the advice hook answering a lookup in place (``InPlaceAnswerer``) runs in a process the harness gives none, and passes the one its payload names. `via` says which face answered where it was not the server — `hook` for that answer, `cli` for a query subcommand run from a shell (``SiftCLI/LoggedLookup``) — so every reader can tell them apart, and one that does not ask counts all three as the index serving a lookup.
    public func record(
        tool: String,
        target: String?,
        targets: [String] = [],
        root: String,
        milliseconds: Int,
        succeeded: Bool,
        error: String? = nil,
        answer: AnswerBytes? = nil,
        agent: String? = nil,
        session: String? = Self.currentSession,
        via: String? = nil,
        located: [String] = [],
        miss: Bool = false,
        parts: [MeasuredAnswer.Part] = []
    ) {
        var entry: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "tool": tool,
            "root": root,
            "ms": milliseconds,
            "ok": succeeded,
        ]
        if targets.count > 1 {
            entry["targets"] = targets
        } else if let target {
            entry["target"] = target
        }
        // Whose session this call belongs to, so a session's calls can be told from every other's.
        // Claude Code puts it in the server's environment; a machine running the CLI directly has no
        // session and records none, which is exactly right — there is no session to attribute it to.
        if let session, !session.isEmpty {
            entry["session"] = session
        }
        if let via {
            entry["via"] = via
        }
        // And *which context inside* that session, where a hook was there to say so. A subagent's calls
        // arrive under its parent's session id and are otherwise indistinguishable from its parent's, which
        // would leave the whole of the subagent work this tool is judged on unattributable. Present only
        // where it is known, so a line from a machine with no hook decodes exactly as one written without
        // the field.
        if let agent, !agent.isEmpty {
            entry["agent"] = agent
        }
        if let error {
            entry["err"] = Self.condensed(error)
        }
        // The files a `where` or `search` answer listed, which locate them for a later window of this context
        // (``DigestedFiles/locates(_:session:agent:resolve:)``). Absent where there are none, so every other
        // line decodes exactly as before.
        if !located.isEmpty {
            entry["located"] = located
        }
        // A digest that resolved nothing is still an answered call (`ok` is true, and the figures that read it
        // keep counting it), but it served nothing to locate a file by: marked, so nothing credits it
        // (``DigestMiss``). Absent otherwise, so a line from before the field reads as no miss.
        if miss {
            entry["miss"] = true
        }
        // What each name of a target string answered as several served, so a later whole read is credited as the
        // separate calls would credit it (``DigestedFiles``). Absent for every other answer, so it decodes as before.
        if !parts.isEmpty {
            entry["parts"] = parts.map(Self.entry(of:))
        }
        if let answer {
            entry["outBytes"] = answer.served
            if let source = answer.source {
                entry["srcBytes"] = source
            }
        }
        log.append(entry)
    }

    /// One part of a split digest answer as its line records it: the name, and the file, served-instead mark and source it carries where it has them.
    private static func entry(of part: MeasuredAnswer.Part) -> [String: Any] {
        var entry: [String: Any] = ["target": part.target]
        if let file = part.file {
            entry["file"] = file
        }
        if part.servedInstead {
            entry["servedInstead"] = true
        }
        if let source = part.source {
            entry["srcBytes"] = source
        }
        return entry
    }

    /// One bounded line — the log is a tally, not a transcript; enough to group a week's failures by cause without re-running each call.
    private static func condensed(_ error: String) -> String {
        let flattened = error.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard flattened.count > 160 else { return flattened }
        return String(flattened.prefix(159)) + "…"
    }
}
