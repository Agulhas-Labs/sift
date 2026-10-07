//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import SiftMCP

/// The four query subcommands' one shared exit: print the answer, then record the lookup in `~/.sift/usage.jsonl` exactly as the server records its own.
///
/// **Both faces are one binary over one ``SiftCore/SiftEngine``**, and the saving is computed at call time from what was served against the source it stood in for — so a lookup the CLI answered holds the same numbers, at the same point, as the same lookup through the MCP tools. Leaving them out did not make the CLI cheaper to measure; it made the measurement wrong, over roughly half the answers the index gave.
///
/// Appending from a short-lived CLI process needs nothing new: ``SiftMCP/UsageLog`` is already written that way by the `PreToolUse` hook, which is an ordinary `sift` invocation, so concurrent append, redaction and root attribution are settled (``SiftMCP/JSONLineLog``).
///
/// **One call, one line.** The record is written here, at the subcommand's own exit, and nowhere in `SiftCore` — which is what keeps the hook's in-place answers counted once: ``SiftMCP/InPlaceAnswerer`` opens an engine inside the hook's process rather than running a subcommand, and logs the call itself (`via: hook`).
struct LoggedLookup {
    /// Serves `lookup`, prints it, and records it — rethrowing whatever the lookup threw, with the failure on the record.
    ///
    /// **Printed before it is recorded**, which is the opposite of the server's order and for the same reason the server chose its own: there the risk is a corrupted JSON-RPC stream, so the write happens while nothing is half-emitted; here the answer *is* the latency, a person or an agent is waiting on it, and a tally has no business between the engine and stdout. The milliseconds are taken before either, so they measure the lookup rather than the terminal.
    ///
    /// `session` is the conversation Claude Code put in this process's environment, read through the same accessor the server reads it through, and absent for a `sift where` typed at a prompt — never inferred from anything else about the environment. The field has always tolerated a call with no caller.
    ///
    /// `agent` is the subagent the `PreToolUse` hook saw on the Bash call that started this process, claimed from the slip it left under this session and this process's own argv (``SiftMCP/CallAttribution/take(session:arguments:)``) — and absent without a session, since a slip is filed under one, and wherever no slip matches, exactly as a server call with no hook is.
    ///
    /// `via: "cli"` marks the face, on the reading ``SiftMCP/UsageLog/record(tool:target:targets:root:milliseconds:succeeded:error:answer:agent:session:via:located:miss:)`` gives the field: the server's calls carry none, and a reader that does not ask counts every face as the index serving a lookup. The latency percentiles do ask, and should: these milliseconds include opening the engine in a fresh process, exactly as the hook's do.
    ///
    /// **The record never speaks.** The answer is what this process's output is for, and an agent reads all of it, stderr included: a shell sandbox that cannot write `~/.sift` (Codex's) put a line about the log in every answer that shell got. A write the log refuses is dropped without a word.
    ///
    /// `locates` is false for an answer as of another revision: the files a `where` or `search` answer listed are recorded beside it (`DigestedFiles.locatedFiles`) only where they are today's.
    static func emit(
        tool: String,
        target: String?,
        targets: [String] = [],
        in directory: URL,
        usage: UsageLog = .standard(),
        session: String? = UsageLog.currentSession,
        arguments: [String] = Array(CommandLine.arguments.dropFirst()),
        callers: CallAttribution = .standard(),
        locates: Bool = true,
        serving: () async throws -> Served
    ) async throws {
        let agent = session.flatMap { callers.take(session: $0, arguments: arguments) }
        let started = Date()
        do {
            let served = try await serving()
            let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
            CommandOutput.standard.emit(served.text)
            usage.record(
                tool: tool,
                target: target,
                targets: targets,
                root: served.root,
                milliseconds: milliseconds,
                succeeded: true,
                answer: AnswerBytes(served: served.text.utf8.count, source: served.source),
                agent: agent,
                session: session,
                via: "cli",
                located: locates ? DigestedFiles.locatedFiles(inAnswer: served.text, tool: tool, parts: served.parts) : [],
                miss: tool == "digest" && DigestMiss.isMiss(inAnswer: served.text),
                parts: served.parts
            )
        } catch {
            // No engine, so no repository: the directory the call named is the only root there is to file the
            // failure under, and it is the one a reader narrowing by `--root` would look for it in.
            usage.record(
                tool: tool,
                target: target,
                targets: targets,
                root: directory.standardizedFileURL.path,
                milliseconds: Int(Date().timeIntervalSince(started) * 1000),
                succeeded: false,
                error: "\(error)",
                agent: agent,
                session: session,
                via: "cli"
            )
            throw error
        }
    }
}

extension LoggedLookup {
    /// One lookup the CLI served: what went to stdout, the repository it was answered from, and the source it stood in for where the tool weighed one.
    struct Served {
        let text: String
        /// The repository the answer was computed against, never the directory the call named — a rootless call is routinely answered from an adopted root, and every per-repository figure read off the log trusts this field.
        let root: String
        /// Present only for a `digest`, which is the one query with an honest denominator; see ``SiftCore/MeasuredAnswer/Bytes`` for why the halves are not symmetric.
        var source: Int?
        /// What each name of a target string answered as several served (``SiftCore/MeasuredAnswer/parts``); empty for every other answer.
        var parts: [MeasuredAnswer.Part] = []
    }
}
